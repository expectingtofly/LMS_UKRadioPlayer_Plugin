package Plugins::UKRadioPlayer::RadioFavourites;

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

use Slim::Utils::Log;
use JSON::XS::VersionOneAndTwo;
use HTTP::Date;
use Data::Dumper;

my $log = logger('plugin.ukradioplayer');


sub getStationData {
	my ( $stationUrl, $stationKey, $stationName, $nowOrNext, $cbSuccess, $cbError) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationData");

	if ($nowOrNext eq 'next') {
		$log->error('Next not supported');
		$cbError->(
			{
				url       => $stationUrl,
				stationName => $stationName
			}
		);
		return;
	}

	my $callUrl = 'https://np.radioplayer.co.uk/qp/v4/schedule?rpId=' . $stationKey;

	main::INFOLOG && $log->is_info && $log->info("Calling $callUrl");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${$http->contentRef};

			#decode the json
			my $jsonOnAir = decode_json $content;

			my $det = $jsonOnAir->{results}->{'now'};

			if ( $det->{type} eq 'PI') {

				my $result = {
					title =>  $det->{programmeName},
					description => $det->{programmeDescription},
					image => $det->{imageUrl},
					startTime => int($det->{startTime}),
					endTime   => int($det->{stopTime}),
					url       => $stationUrl,
					stationName => $stationName
				};
				$cbSuccess->($result);

			} else {

				#Do the best we can

				my $result = {
					title =>  'n/a',
					description => 'No programme information available for ' . $stationName . ' from RadioPlayer try the native plugin',
					image => $det->{imageUrl},
					startTime => 0,
					endTime   => 0,
					url       => $stationUrl,
					stationName => $stationName
				};
				$cbSuccess->($result);
			}

		},

		# Called when no response was received or an error occurred.
		sub {
			$log->error('Failed to retrieve on air text');
			$cbError->(
				{
					url       => $stationUrl,
					stationName => $stationName
				}
			);
		}
	)->get($callUrl);

	return;
}


1;

