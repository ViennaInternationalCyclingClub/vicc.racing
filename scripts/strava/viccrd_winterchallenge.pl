#!/usr/bin/perl

use strict;
use warnings;

use Cpanel::JSON::XS;
use Text::CSV_XS;
use File::Temp qw/ tempfile /;
use DateTime;
use DateTime::Format::Strptime 'strptime';
use WebService::Strava;
use Net::Google::Drive::Simple;
use Geo::Coder::Google;
use Getopt::Long;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my %opts;
GetOptions(\%opts,
    'apikey=s',
    'tokendir=s',
);
die "Need apikey and tokendir parameters\n" unless ($opts{apikey} and $opts{tokendir});

my $json = Cpanel::JSON::XS->new;

my $activity_window_after_datetime = '2022-02-01'; # apparently starting with 00:00:00 (inclusive)
my $activity_window_before_datetime = '2022-03-01';
my $before_epoch = strptime('%F',$activity_window_before_datetime)->epoch();
my $after_epoch = strptime('%F',$activity_window_after_datetime)->epoch();

# my $racingdivision_club = 180386;
# my $requested_club;
# foreach my $club ( @{$strava->clubs()} ) {
#     if ( $club->id == $racingdivision_club ) {
#         $requested_club = $club;
#         last;
#     }
# }

my $challenge_activity_title_re = qr/viccrd winter challenge,?([0-9,+# ]+)/i;
my @base_activity_fields = qw(id name total_elevation_gain average_temp suffer_score
    average_watts moving_time elapsed_time start_date_local distance
    start_latitude start_longitude type photo_count commute);

my $geocoder = Geo::Coder::Google->new(apiver => 3, apikey => $opts{apikey} );
my $field_calculations = {
    'start_geocoded_coordinates' => sub {
        my ($activity) = @_;
        return '' unless defined $activity->{start_latitude};
        return 'At some virtual place' if $activity->{type} =~ /virtual/i;

        my $location = $geocoder->reverse_geocode(latlng => $activity->{start_latitude}.','.$activity->{start_longitude});
        return $location->{formatted_address},
    },
};
my @calculated_fields = keys %$field_calculations;

my $challenge_count = 15;
my @claimed_challenge_fields = map { "claimed_challenge_$_" } (1..$challenge_count);

my $activity_header_row = [ 'athlete_name', 'athlete_id', @base_activity_fields, @calculated_fields, 'description', @claimed_challenge_fields ];

my ($fh, $filename) = tempfile( TEMPLATE => 'viccrd-winterchallenge-202202-XXXXX', SUFFIX => '.csv', TMPDIR => 1, CLEANUP => 0 );
binmode $fh, ":encoding(utf8)";

my $csv = Text::CSV_XS->new({ auto_diag => 1, binary => 1});
$csv->say($fh, $activity_header_row);

if ( ! -d $opts{tokendir} ) {
    die "Could not find $opts{tokendir}";
}
opendir(my $dirfh, $opts{tokendir}) or die "Could not open ".$opts{tokendir}."\n";
while (my $fn = readdir($dirfh)) {
    my $tokenfile = $opts{tokendir}.'/'.$fn;
    next unless -f $tokenfile;
    if ( ! -r $tokenfile ) {
        warn "Can not read '$tokenfile'\n";
        next;
    }

    my $auth = WebService::Strava::Auth->new(
      config_file => $tokenfile,
    );
    my $strava = WebService::Strava->new( auth => $auth );
    my $activities = $strava->auth->get_api("/athlete/activities?after=$after_epoch&before=$before_epoch&per_page=99");
    my $athlete = $strava->athlete();
    my $athlete_identifier = sprintf("%s %s", $athlete->{firstname}, $athlete->{lastname});

    my $activity_count = 0;
    foreach my $activity (@$activities) {
        #next unless $activity->{name} =~ /$challenge_activity_title_re/;
        $csv->say($fh, activity_to_row($athlete, $activity, $strava));
        $activity_count++;
    }
    warn sprintf("Got %d challenge activities from athlete '%s'\n", $activity_count, $athlete_identifier);
}
closedir($dirfh);
close $fh or die "$filename: $!";
warn "Wrote $filename\n";

my $gd = Net::Google::Drive::Simple->new();
my ($children, $parent) = $gd->children('/VICC/RacingDivision/Events & Activities/Winter Challenge 2022');
if ( my $file_id = $gd->file_upload( $filename, $parent ) ) {
    warn "Uploaded $filename as $file_id to folder " . $parent . "\n";
}
else {
    warn "Could not upload $filename\n";
}

sub activity_to_row {
    my ($athlete, $activity, $strava) = @_;

    my $row = [
        $athlete->{firstname} . ' ' . $athlete->{lastname},
        $athlete->{id},
        map { $_ =~ /name/ ? _sanitize_text($activity->{$_}) : $activity->{$_} } @base_activity_fields,
    ];
    foreach my $calculated_field ( @calculated_fields ) {
        push @$row, $field_calculations->{$calculated_field}($activity);
    }

    my $description = '';
    my ($claimed_challenges) = ( $activity->{name} =~ /$challenge_activity_title_re/ );
    if ( not defined $claimed_challenges ) {
        my $activity_detail = $strava->auth->get_api("/activities/".$activity->{id});
        if ( defined $activity_detail and defined $activity_detail->{description} ) {
            $description = _sanitize_text($activity_detail->{description});
            ($claimed_challenges) = ( $description =~ /$challenge_activity_title_re/ );
        }
    }
   push @$row, $description;
    if ( defined $claimed_challenges ) {
        $claimed_challenges =~ s/#//g;
        $claimed_challenges =~ s/\+/,/;
        $claimed_challenges =~ s/\s+/ /;
        my %claims;
        map { $claims{$_} = 1 } split(/[, ]/, $claimed_challenges);
        foreach my $i (1..$challenge_count) {
            push @$row, $claims{$i} ? 1: 0;
        }
    }

    return $row;
}

sub _sanitize_text {
    my ($text) = @_;

    return '' unless defined $text;

    $text =~ s/\P{XPosixPrint}\t\r\n/ /g;
    return $text;
}

# Monkeypatch to support CSV-Google Spreadsheet conversion
no warnings 'redefine';
sub Net::Google::Drive::Simple::file_mime_type {
    my( $self, $file ) = @_;

    return 'application/vnd.google-apps.spreadsheet' if $file =~ /\.csv$/;

    if( !$self->{ magic } ) {
        $self->{ magic } =  File::MMagic->new();
    }

    return $self->{ magic }->checktype_filename( $file );
}
