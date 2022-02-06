#!/usr/bin/perl

use strict;
use warnings;

use CGI::Simple;
use utf8;
binmode(STDOUT, ':utf8');

use JSON qw(decode_json encode_json);
use LWP::Authen::OAuth2;
use Config::Tiny;

my $q = CGI::Simple->new;

my $oauth2 = LWP::Authen::OAuth2->new(
    client_id => $ENV{STRAVA_APP_CLIENT_ID},
    client_secret => $ENV{STRAVA_APP_CLIENT_SECRET},
    service_provider => "Strava",
    redirect_uri => $ENV{STRAVA_APP_REDIRECT_URI},
    scope => 'read,activity:read,activity:read_all',
);

my $code = $q->param( 'code' );
my $connect = $q->param( 'connect' );
if ( defined $code  )  {
    eval {
        $oauth2->request_tokens(code => $code);
    };
    if ( $@ ) {
        print $q->header( -status => 500, );
        print "Something went wrong: <pre>".$@."</pre";
        print 'Please contact '. $ENV{CONTACT_MAIL};
        exit;
    }

    my $config = Config::Tiny->new();
    $config->{auth}{client_id} = $ENV{STRAVA_APP_CLIENT_ID};
    $config->{auth}{client_secret} = $ENV{STRAVA_APP_CLIENT_SECRET};

	$config->{auth}{token_string} = $oauth2->token_string;

    my $ok;
    if ( $config->{auth}{token_string} ) {
        my $token_string_json = decode_json($config->{auth}{token_string});
        if ( not(defined $token_string_json) or not(exists $token_string_json->{athlete}) ) {
            warn "Could not decode token_string or athlete data is missing:";
            use Data::Dumper;
            warn Dumper $config->{auth}{token_string};
        }
        elsif ( $config->write($ENV{TOKEN_STORAGE_DIRECTORY} . ($token_string_json->{athlete}->{username}||$token_string_json->{athlete}->{id})) ) {
            print $q->header( -status => 200, -content_type => 'text/html; charset=utf-8' );
            print <<EOS;
<html><head><title>Connected with Strava</title><style>body {font-family: Arial, Helvetica, sans-serif; } div, label, input { font-size: 1.5em; }</style></head>
<body>
<h1>Connected with Strava. Ride on!</h1>
</body>
</html>
EOS
        }
        $ok = 1;
    }
    if ( not $ok ) {
        print $q->header( -status => 500, );
        print 'Something went wrong. Please contact '. $ENV{CONTACT_MAIL};
    }
    exit;
}
elsif ( defined $connect and $connect ) {
    print $q->redirect($oauth2->authorization_url());
    exit;
}

print $q->header( -status => 200, -content_type => 'text/html; charset=utf-8' );
print <<EOS;
<html><head><title>Connect with Strava</title><style>body {font-family: Arial, Helvetica, sans-serif; } div, label, input { font-size: 1.5em; }</style></head>
<body>
<div>
EOS

print <<EOS;
<div style="text-align: center; margin-top: 50px;">
<image src="/viccrd/images/viccrd-icon-250x250.png" width="250" height="250" alt="VICCRD Icon"/>
<form action="$ENV{SCRIPT_NAME}">
    <input type="hidden" name="connect" value="1"/>
    <input type="image" src="/viccrd/images/btn_strava_connectwith_orange@2x.png" alt="Connect with Strava"/>
</form>
</div>
</div>
</body>
</html>
EOS

__END__

=pod

Sample nginx config block:

    location /stravaconnect/ {
        gzip off;
        fastcgi_pass  unix:/var/run/fcgiwrap.socket;
        include /etc/nginx/fastcgi_params;
        root   /var/www/somevhost;
        fastcgi_index index.cgi;
        fastcgi_param STRAVA_APP_CLIENT_ID $somevalue;
        fastcgi_param STRAVA_APP_CLIENT_SECRET $somevalue
        fastcgi_param STRAVA_APP_REDIRECT_URI $public_uri_for_index.cgi;
        fastcgi_param CONTACT_MAIL $somevalue;
        fastcgi_param TOKEN_STORAGE_DIRECTORY $directory_with_trailing_slash;
        fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
   }

