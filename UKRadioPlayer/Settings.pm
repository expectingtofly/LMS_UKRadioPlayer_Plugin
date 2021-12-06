package Plugins::UKRadioPlayer::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.ukradioplayer');

sub name {
    return 'PLUGIN_UKRADIOPLAYER';
}

sub page {
    return 'plugins/UKRadioPlayer/settings/basic.html';
}

sub prefs {  
    return ( $prefs, qw(is_radio) );
}

1;