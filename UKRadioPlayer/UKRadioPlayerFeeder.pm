package Plugins::UKRadioPlayer::UKRadioPlayerFeeder;

# Copyright (C) 2021 Stuart McLean stu@expectingtofly.co.uk

#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.

use warnings;
use strict;

use URI::Escape;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;

use Data::Dumper;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);

use POSIX qw(strftime);
use HTTP::Date;

use Plugins::UKRadioPlayer::ProtocolHandler;
use Plugins::UKRadioPlayer::Utilities;


my $log = logger('plugin.ukradioplayer');
my $prefs = preferences('plugin.ukradioplayer');

my $isRadioFavourites;

my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }

sub init {
	$isRadioFavourites = Slim::Utils::PluginManager->isEnabled('Plugins::RadioFavourites::Plugin');
}

sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");

	my @radioprefixarr = ('#', 'A', 'B', 'C', 'D', 'E', 'F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z');

	my $items = [];

	for my $letter (@radioprefixarr) {
		push @$items,
		  {
			name => $letter,
			type => 'link',
			url =>  \&servicesMenu,
			passthrough =>  [ { item => $letter, codeRef => 'servicesMenu' } ]
		  };
	}


	my $menu = [
		{
			name => 'Search for stations and shows',
			type => 'search',
			url => \&searchRadioPlayer,

		},
		{
			name => 'All RadioPlayer Stations [a-z]',
			type => 'link',
			items => $items

		}
	];

	$callback->( { items => $menu } );
	return;
}


sub searchRadioPlayer {
	my ( $client, $callback, $args, $passDict ) = @_;
	my $searchstr = $args->{'search'};
	my $callUrl = 'https://api.radioplayer.co.uk/metadata/api/v2/suggest?query=' . URI::Escape::uri_escape_utf8($searchstr) . '&lang=en';


	_callAPI(
		$callUrl,
		sub {
			my $JSON = shift;
			my $serviceMenu = [];
			my $onDemandMenu = [];
			my $arr = $JSON->{response}->{live};
			for my $service (@$arr) {
				_createServiceMenuItem($serviceMenu, $service, $service->{rpId});
			}

			$arr = $JSON->{response}->{onDemand};
			for my $service (@$arr) {
				_createOnDemandMenuItem($onDemandMenu, $service);
			}

			my $stationCount = 0;
			my $onDemandCount = 0;

			$stationCount = scalar @{ $JSON->{response}->{live} } if defined $JSON->{response}->{live};
			$onDemandCount = scalar @{ $JSON->{response}->{onDemand} } if defined $JSON->{response}->{onDemand};


			my $menu = [
				{
					name => "$stationCount Stations...",
					type => 'link',
					items => $serviceMenu
				},
				{
					name => "$onDemandCount Shows...",
					type => 'link',
					items => $onDemandMenu
				}
			];
			$callback->( { items => $menu } );


		},

		sub {
			my $menu = [
				{
					name =>'ERROR - Search Failed'
				}
			];
			$callback->( { items => $menu } );
		}
	);


}


sub servicesMenu {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++servicesMenu");

	my $letter =  lc $passDict->{'item'};

	my $menu = [];

	my $filter = sub {
		my $sarr = shift;

		for my $service (@$sarr) {
			if ($service->{alphanumericKey} eq $letter) {
				_createServiceMenuItem($menu, $service, $service->{id});
			}
		}

		$callback->( { items => $menu } );

	};

	retrieveServices(
		$filter,
		sub {
			$menu = [
				{
					name =>'ERROR - Could not get service list'
				}
			];
			$callback->( { items => $menu } );
		}
	);


	main::DEBUGLOG && $log->is_debug && $log->debug("++servicesMenu");
	return;
}


sub retrieveServices {
	my ( $cbY, $cbN ) = @_;

	if (my $csarr = _getCachedMenu('radioplayer://TopServices')) {
		$cbY->($csarr);
	}else {

		getServices(
			sub {
				my $servicesJSON = shift;
				my $arr = $servicesJSON->{services};
				_cacheMenu('radioplayer://TopServices',$arr,86400);
				$cbY->($arr);
			},
			$cbN
		);
	}

}


sub getStreamByRpid {
	my ( $rpid, $cbY, $cbN ) = @_;

	retrieveServices(
		sub {
			my $sarr = shift;
			for my $service (@$sarr) {
				if ($service->{id} eq $rpid) {
					$cbY->(_livestreamSelector($service->{liveStreams}[0]->{audioStreams}));
					last;
				}
			}
		},
		$cbN
	);
}


sub _createServiceMenuItem {
	my ( $menu, $serviceJSON, $id ) = @_;

	my $url = 'radioplayeruk://_LIVE_' . $id;

	main::DEBUGLOG && $log->is_debug && $log->debug('Service Item Dump : ' . Dumper($serviceJSON));

	if ( my $plyr = $serviceJSON->{liveStreams}[0]->{player} ) {
		if ($plyr =~ /^https:\/\/www.bbc.co.uk\/sounds\/player\//) {
			my ($bbcId) = $plyr =~ /^https:\/\/www.bbc.co.uk\/sounds\/player\/(.*)/;

			$url = 'sounds://_LIVE_' . $bbcId;
		}	
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Url  : ' . $url);


	my $service = {
		name => $serviceJSON->{name},
		type => 'audio',
		url => $url,
		image => $serviceJSON->{multimedia}[0]->{url},
		on_select   => 'play'
	};

	if ($isRadioFavourites) {
		$service->{itemActions} = getItemActions($serviceJSON->{name}, $url, $id);
	}

	push @$menu, $service;

	return;

}


sub getItemActions {
	my $name = shift;
	my $url = shift;
	my $key = shift;
	return  {
		info => {
			command     => ['radiofavourites', 'addStation'],
			fixedParams => {
				name => $name,
				stationKey => $key,
				url => $url,
				handlerFunctionKey => 'ukradioplayer'
			}
		},
	};
}


sub _createOnDemandMenuItem {
	my ( $menu, $serviceJSON ) = @_;

	my $liveStreams = $serviceJSON->{liveStreams};

	main::DEBUGLOG && $log->is_debug && $log->debug('On Demand Item Dump : ' . Dumper($serviceJSON));

	my $streamSource = _livestreamSelector($serviceJSON->{onDemandStreams}[0]->{audioStreams});
	my $url = $streamSource->{'url'};

	if ( my $plyr = $serviceJSON->{player} ) {
		if ($plyr =~ /\/www.bbc.co.uk\//) {
			my ($id) = $plyr =~ /\/player\/(.*)/;
			my ($pid) = $url =~/json\/vpid\/(.*)\/mediaset\//;

			$url = 'sounds://_' . $pid . '_' . $id . '_0';
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("On Demand Url : $url");

	push @$menu,
	  {
		name => $serviceJSON->{name},
		type => 'audio',
		url => $url,
		image => $serviceJSON->{multimedia}[0]->{url},
		on_select   => 'play'
	  };

	return;

}


sub _livestreamSelector {
	my ($streamJSON) = @_;

	if ((scalar @$streamJSON) > 1 ) {

		@$streamJSON = reverse sort { $a->{bitRate}->{target} <=> $b->{bitRate}->{target} } @$streamJSON;

	}

	return {
		url => @$streamJSON[0]->{streamSource}->{url},
		mimeValue => @$streamJSON[0]->{streamSource}->{mimeValue},
		bitRate => @$streamJSON[0]->{bitRate}->{target}
	};

}


sub getServices {
	my ($cbY, $cbN ) = @_;
	my $callUrl = "https://api.radioplayer.co.uk/metadata/api/v2/services?lang=en";
	_callAPI($callUrl, $cbY, $cbN );

}


sub getOnAir {
	my ($cbY, $cbN, $rpid ) = @_;
	my $callUrl = "https://np.radioplayer.co.uk/qp/v4/onair?rpIds=$rpid";
	_callAPI(
		$callUrl,
		sub {
			my $JSON = shift;
			$cbY->($JSON->{results}->{"$rpid"});
		},
		$cbN
	);
}


sub _callAPI {
	my ($callUrl, $cbY, $cbN) = @_;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			$cbY->($JSON);
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$cbN->();
		}
	)->get(
		$callUrl,
		'User-Agent' => 'Dalvik/2.1.0 (Linux; U; Android 6.0.1; Nexus 5 Build/M4B30Z',
		'Accept' => 'application/json',
		'Authorization' => 'Basic dWtycG1vYmlsZTo0dVN3ZWJldDNrYWN1cUVk'
	);
}


sub _getCachedMenu {
	my ($url) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getCachedMenu");

	my $cacheKey = 'RP:' . md5_hex($url);

	if ( my $cachedMenu = $cache->get($cacheKey) ) {
		my $menu = ${$cachedMenu};
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu got cached menu");
		return $menu;
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu no cache");
		return;
	}
}


sub _cacheMenu {
	my ( $url, $menu, $seconds ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_cacheMenu");
	my $cacheKey = 'RP:' . md5_hex($url);
	$cache->set( $cacheKey, \$menu, $seconds );

	main::DEBUGLOG && $log->is_debug && $log->debug("--_cacheMenu");
	return;
}


sub _renderMenuCodeRefs {
	my $menu = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_renderMenuCodeRefs");

	for my $menuItem (@$menu) {
		my $codeRef = $menuItem->{passthrough}[0]->{'codeRef'};
		if ( defined $codeRef ) {
			if ( $codeRef eq 'callAPI' ) {
				$menuItem->{'url'} = \&callAPI;
			}else {
				$log->error("Unknown Code Reference : $codeRef");
			}
		}
		if (defined $menuItem->{'items'}) {
			_renderMenuCodeRefs($menuItem->{'items'});
		}

	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_renderMenuCodeRefs");
	return;
}

1;
