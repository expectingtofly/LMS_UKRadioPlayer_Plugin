package Plugins::UKRadioPlayer::ProtocolHandler;

use warnings;
use strict;

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;

use URI::Escape;
use HTTP::Date;

use Plugins::UKRadioPlayer::UKRadioPlayerFeeder;

use Data::Dumper;


my $log = logger('plugin.ukradioplayer');
my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }

Slim::Player::ProtocolHandlers->registerHandler('radioplayeruk', __PACKAGE__);


sub new {
	my $class  = shift;
	my $args   = shift;

	$log->debug("New called ");


	my $client = $args->{client};

	my $song      = $args->{song};

	my $streamUrl = $song->streamUrl() || return;
	my $track     = $song->pluginData();

	$log->info( 'Remote streaming station : ' . $streamUrl . ' actual url' . $song->track()->url);


	my $sock = $class->SUPER::new(
		{
			url     => $streamUrl,
			song    => $song,
			client  => $client,
		}
	) || return;

	my $rpid = Plugins::UKRadioPlayer::ProtocolHandler::getId($song->track()->url);

	#${*$sock}{contentType} = 'audio/mpeg';
	${*$sock}{'song'}   = $args->{'song'};
	${*$sock}{'client'} = $args->{'client'};
	${*$sock}{'vars'} = {
		'metaDataCheck' => time(),
		'isLive' => 1,
		'rpid' =>$rpid
	};

	return $sock;
}


sub formatOverride {
	my $self = shift;
	my $song = shift;


	my $mimeType = $song->pluginData('mime');

	main::INFOLOG && $log->is_info && $log->info("Mime type $mimeType");

	my $format = 'unk';

	if ($mimeType eq 'audio/mpeg') {
		$format = 'mp3';
	}elsif ($mimeType eq 'audio/aac') {
		$format = 'aac';
	}elsif ($mimeType eq 'audio/aacp') {
		$format = 'aac';
	}elsif ($mimeType eq 'audio/x-scpls') {
		$format = 'mp3';
	}else {
		$format = 'mp3';
	}
	main::INFOLOG && $log->is_info && $log->info("Url format $format");
	return $format;

}


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}


sub _getOnAirType {
	my $onAirArr = shift;
	my $type = shift;

	for my $item (@$onAirArr) {
		if ($item->{type} eq $type) {
			main::DEBUGLOG && $log->is_debug && $log->debug('on air dump '. Dumper($item));
			return $item;
		}
	}
	return; #not found
}


sub readMetaData {
	my $self = shift;

	my $v = $self->vars;
	my $rpid = $v->{'rpid'};


	if ($v->{'isLive'}) {
		if (time() > $v->{'metaDataCheck'}) {
			my $song = ${*$self}{'song'};
			main::INFOLOG && $log->is_info && $log->info('Setting new live meta data' . $rpid . ' at :' . $v->{'metaDataCheck'});

			$v->{'metaDataCheck'} = time() + 360; #safety net so we never flood


			Plugins::UKRadioPlayer::UKRadioPlayerFeeder::getOnAir(
				sub {
					my $json = shift;
					my $meta = {
						type  => 'UKRadioPlayer',
						title =>  '',
						artist => '',
						icon  =>  '',
						album =>  '',
						cover =>  '',
						bitrate => $song->pluginData('bitrate'),
					};

					if (my $siItem = _getOnAirType($json, 'SI')) {  #station
						$meta->{title} = $siItem->{'serviceName'};
						$meta->{artist} = $siItem->{'description'};
						$meta->{icon} = $siItem->{'imageUrl'};
						$meta->{cover} = $siItem->{'imageUrl'};
					}

					if (my $piItem = _getOnAirType($json, 'PI')) {  #programme
						$meta->{artist} = $piItem->{'name'};
						$meta->{icon} = $piItem->{'imageUrl'};
						$meta->{cover} = $piItem->{'imageUrl'};

						$v->{'metaDataCheck'} = $piItem->{'stopTime'};

						if ( $v->{'metaDataCheck'} < (time() + 30)) {
							$v->{'metaDataCheck'} = (time() + 180);
						}
						if ( $v->{'metaDataCheck'} > (time() + 180) ) {
							$v->{'metaDataCheck'} = (time() + 180);
						}
					}

					if (my $eiItem = _getOnAirType($json, 'PE_E')) {  #Song
						if ($eiItem->{'stopTime'} > time() ) {
							if ($eiItem->{'startTime'} < time()) {
								$meta->{title} =  $eiItem->{'name'} . ' by ' . $eiItem->{'artistName'};
								$meta->{icon}  =  $eiItem->{'imageUrl'};
								$meta->{cover} =  $eiItem->{'imageUrl'};
								$meta->{album} =  $eiItem->{'serviceName'};
								$v->{'metaDataCheck'} = ($eiItem->{'stopTime'} + 5);

								if ($v->{'metaDataCheck'} < (time() + 30)) {
									$v->{'metaDataCheck'} = (time() + 30);

								}
							} else {#not there yet
								$v->{'metaDataCheck'} = (time() + 60);
							}
						} else {
							$v->{'metaDataCheck'} = (time() + 60);
						}
					}

					my $client = ${*$self}{'client'};	
					my $cb = sub {
						main::INFOLOG && $log->is_info && $log->info("Setting title back after callback");				
						
						$song->pluginData( meta  => $meta );										
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );					
					};			

					#the title will be set when the current buffer is done
					Slim::Music::Info::setDelayedCallback( $client, $cb );					

					main::INFOLOG && $log->is_info && $log->info('We will check again ' .	$v->{'metaDataCheck'} );				
					
					
				},
				sub {
					my $meta =      {
						type  => 'UKRadioPlayer',
						title => 'Unknown',
					};

					$log->error('Could not get live meta data');

					#place on the song
					$song->pluginData( meta  => $meta );

					${*$self}{'metaDataCheck'} = time() + 120;
				},
				$rpid
			);
		}
	}
	$self->SUPER::readMetaData(@_);

}


sub close {
	my $self = shift;

	${*$self}{'active'} = 0;

	main::INFOLOG && $log->is_info && $log->info('close called');

	$self->SUPER::close(@_);
}


sub canDirectStream {
	my ($classOrSelf, $client, $url, $inType) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug('Never direct stream');

	return 0;
}


sub canSeek {
	my ( $class, $client, $song ) = @_;

	return 0;

}

sub isRemote { 1 }


sub scanUrl {
	my ($class, $url, $args) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("scanurl $url");

	my $rpid = Plugins::UKRadioPlayer::ProtocolHandler::getId($url);

	Plugins::UKRadioPlayer::UKRadioPlayerFeeder::getStreamByRpid(
		$rpid,
		sub {
			my $streamSource = shift;

			my $newurl = $streamSource->{'url'};
			main::DEBUGLOG && $log->is_debug && $log->debug("scanurl $url real url $newurl");


			#let LMS sort out the real stream
			my $realcb = $args->{cb};

			$args->{cb} = sub {
				main::DEBUGLOG && $log->is_debug && $log->debug('Current Track : ' . $args->{song}->currentTrack());
				$realcb->($args->{song}->currentTrack());
			};
			Slim::Utils::Scanner::Remote->scanURL($newurl, $args);
		},
		sub {
			$log->error("Scan URL Failed, no track");
		}
	);
}


sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('++getNextTrack');

	my $client = $song->master();
	my $masterUrl = $song->track()->url;
	my $trackurl = '';
	my $rpid = Plugins::UKRadioPlayer::ProtocolHandler::getId($masterUrl);

	Plugins::UKRadioPlayer::UKRadioPlayerFeeder::getStreamByRpid(
		$rpid,
		sub {
			my $streamSource = shift;
			my $trackurl = $streamSource->{'url'};
			my $mimeType = $streamSource->{'mimeValue'};
			my $bitrate = $streamSource->{'bitRate'} / 1000;


			main::DEBUGLOG && $log->is_debug && $log->debug("Master : $masterUrl Real $trackurl  mime $mimeType");

			#Resolve redirects, if any..
			my $http = Slim::Networking::Async::HTTP->new;
			my $request = HTTP::Request->new( GET => $trackurl );
			$http->send_request(
				{
					request     => $request,
					onHeaders => sub {
						my $http = shift;
						my $endTrackurl = $http->request->uri->as_string;
						main::DEBUGLOG && $log->is_debug && $log->debug("Master : $masterUrl Real $trackurl  mime $mimeType endUrl $endTrackurl");
						$song->streamUrl($endTrackurl);
						$song->pluginData(mime => $mimeType);
						$song->pluginData(bitrate => "$bitrate" . 'kbps');
						$http->disconnect;
						$successCb->();
					},
					onError => sub {
						my ( $http, $self ) = @_;
						my $res = $http->response;
						$log->error('Error status - ' . $res->status_line );
						$errorCb->();
					}
				}
			);
		},
		sub {
			$errorCb->();
		}
	);

	return;
}


# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;

	main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_TIMESRADIO_STREAM_FAILED' );
}


sub getMetadataFor {
	my ( $class, $client, $full_url ) = @_;
	my $icon = $class->getIcon();

	my ($url) = $full_url =~ /([^&]*)/;

	#its on the song
	my $song = $client->playingSong();

	if ( $song && $song->currentTrack()->url eq $full_url ) {

		if (my $meta = $song->pluginData('meta')) {

			return $meta;
		}

	}
	return {
		type  => 'UKRadioPlayer',
		title => $url,
		icon  => $icon,
	};

}


sub getId {
	my $url = shift;

	my @urlsplit  = split /_/x, $url;
	my $id = URI::Escape::uri_unescape($urlsplit[2]);

	return $id;
}


sub getIcon {
	my ( $class, $url ) = @_;

	return Plugins::UKRadioPlayer::Plugin->_pluginDataFor('icon');
}
1;
