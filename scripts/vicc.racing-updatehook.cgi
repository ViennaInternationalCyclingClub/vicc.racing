#!/usr/bin/perl

use CGI::Simple;
use Digest::SHA qw(hmac_sha1_hex);

my $q = CGI::Simple->new;

my $secret = $ENV{'SECRET'};
my $checkout_directory = $ENV{'CHECKOUT_DIRECTORY'};
my $signature = $ENV{'HTTP_X_HUB_SIGNATURE'};
my $postdata = $q->param( 'POSTDATA' );
my $check_hmac;
if ( defined $secret and defined $signature )  {
    $signature =~ s/sha1=//;
    my $check_hmac = hmac_sha1_hex($postdata, $secret);
    if ( $check_hmac eq $signature ) {
        if ( system("git -C $checkout_directory pull $checkout_directory >/dev/null 2>&1") != 0 ) {
            warn "Repository checkout could not be updated: $!";
        }
        print $q->header(-type => 'application/json');
        print '{1}';
    }
    else {
        print $q->header( -status => 403 );
    }
}
else {
    print $q->header( -status => 403 );
}
