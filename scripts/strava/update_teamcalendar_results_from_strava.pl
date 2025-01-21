#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use DateTime;
use Net::Google::Spreadsheets::V4;
use WebService::Strava;
use Config::INI::Reader;
use Cpanel::JSON::XS;
use DateTime;
use DateTime::Format::Strptime 'strptime';
use Getopt::Long;
use Encode qw(decode encode);
use Text::Levenshtein qw(distance);

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

my %opts;
GetOptions(\%opts,
    'tokendir=s',
    'client_id=s',
    'client_secret=s',
    'refresh_token=s',
    'spreadsheet_id=s',
    'racedaydate=s',
    'target_spreadsheet_name=s',
);
die "Need tokendir, client_id, client_secret, refresh_token and spreadsheet_id parameters\n"
    unless ($opts{tokendir}  and $opts{client_id} and $opts{client_secret} and $opts{refresh_token} and $opts{spreadsheet_id});

my $json = Cpanel::JSON::XS->new->relaxed->binary;

my $raceday = DateTime->today->subtract( days => 1 );
$raceday = strptime('%F',$opts{racedaydate}) if $opts{racedaydate};

my $target_spreadsheet_name = $opts{target_spreadsheet_name};
$target_spreadsheet_name ||= 'RaceParticipations';

my @rider_columns = qw(ID Name Nickname ZP-FTP-Category StravaID ZwiftPowerID);
my @race_columns = ('Rider ID','Race ID','Race Start Date','Race Title','Sortable Combined Race Title','Licensed','Rider','StravaID','StartDateISO8661','EndDateISO8661');
my @strava_activity_columns = qw(id name total_elevation_gain suffer_score average_watts weighted_average_watts max_watts moving_time elapsed_time start_date_local distance);
my $strava_gsheet_column_index_start = 14;

my %rider_column_lookup;
my $i = 0;
foreach my $col ( @rider_columns ) {
    $rider_column_lookup{$col} = $i++;
}

my %race_column_lookup;
$i = 0;
foreach my $col ( @race_columns ) {
    $race_column_lookup{$col} = $i++;
}

# get day wanted
# check race calendar for races on that day
# iterate members sheet with members configured a Strava ID
#   fetch Strava data and apply heuristics to match the race
#   store in result sheet in case

my %known_tokens;
if ( ! -d $opts{tokendir} ) {
    die "Could not find $opts{tokendir}";
}
opendir(my $dirfh, $opts{tokendir}) or die "Could not open ".$opts{tokendir}."\n";
while (my $fn = readdir($dirfh)) {
    my $tokenfile = $opts{tokendir}.'/'.$fn;
    next unless -f $tokenfile;

    my $config_hash = Config::INI::Reader->read_file($tokenfile);
    my $json_string = $config_hash->{auth}->{token_string};
    if ( not (defined $json_string and length $json_string) ) {
        warn "Empty token_string for " . $tokenfile;
        next;
    }
    my $decoded = $json->decode($json_string);
    $known_tokens{$decoded->{athlete}->{id}} = $tokenfile;
}
closedir($dirfh);

my $gs = Net::Google::Spreadsheets::V4->new(
    client_id => $opts{client_id},
    client_secret => $opts{client_secret},
    refresh_token => $opts{refresh_token},
    spreadsheet_id => $opts{spreadsheet_id},
);

my $current_row = 0;
my ($content, $res) = $gs->request(
        GET => '/values/'.$gs->a1_notation(
                sheet_title  => $target_spreadsheet_name,
                start_column => 1,
                end_column   => 14,
                start_row    => $current_row+2,
                end_row      => 999,
            ),
        undef
);
if ( not ( defined $content and defined $res ) ) {
    print "Could not access Google Spreadsheet '$target_spreadsheet_name'";
    exit;
}

printf("Processing race day '%s'\n", $raceday->ymd);

my @requests;
foreach my $race (@{$content->{values}}) {
    ++$current_row;
    last unless defined $race->[$race_column_lookup{'Race ID'}];
    next unless ($race->[$race_column_lookup{'StartDateISO8661'}] and $race->[$race_column_lookup{'StartDateISO8661'}] =~ /^\d/);
    next unless $race->[$race_column_lookup{'EndDateISO8661'}];
    next unless $race->[$race_column_lookup{'StravaID'}];
    next unless exists $known_tokens{$race->[$race_column_lookup{'StravaID'}]};

    my $start_date = strptime('%F', $race->[$race_column_lookup{'StartDateISO8661'}]);
    my $end_date = strptime('%F', $race->[$race_column_lookup{'EndDateISO8661'}]);

    next unless ($start_date <= $raceday and $end_date >= $raceday);

    printf("\nProcessing race %s (%s) for '%s'\n", $race->[$race_column_lookup{'Race Title'}], $race->[$race_column_lookup{'Race ID'}], $race->[$race_column_lookup{'Rider'}]);

    my $auth = WebService::Strava::Auth->new(
        config_file => $known_tokens{$race->[$race_column_lookup{'StravaID'}]},
    );

    my $strava = WebService::Strava->new( auth => $auth );
    my $activities = $strava->auth->get_api(sprintf("/athlete/activities?after=%s&before=%s", $start_date->epoch, $end_date->add( days => 1)->epoch));
    next unless defined $activities;
    if ( ref $activities ne 'ARRAY' ) {
        warn "Error: " . $activities->{message};
        next;
    }

    my $athlete = $strava->athlete();
    my $athlete_identifier = sprintf("%s %s", $athlete->{firstname}, $athlete->{lastname});

    my @race_activity_row;
    # Assuming the activity with the highest suffer score/weighted watts of the day to be the race activity
    my @sorted_activites = reverse sort { defined $a->{suffer_score} ? $a->{suffer_score} <=> $b->{suffer_score} : $a->{weighted_average_watts} <=> $b->{weighted_average_watts} } @$activities;
    printf("\tMost likely race: %s\n", $sorted_activites[0]->{name});

    if ( distance($sorted_activites[0]->{name}, $race->[$race_column_lookup{'Race Title'}], {ignore_diacritics => 1}) > 5 ) {
        printf("\tActivity name '%s' is quite distant from the race calendar name.\n", $sorted_activites[0]->{name});
    }
    elsif ( $sorted_activites[0]->{name} !~ /$race->[$race_column_lookup{'Race Title'}]/ ) {
        printf("\tActivity name '%s' is similar but does not contain race calendar name.\n", $sorted_activites[0]->{name});
    }

    foreach my $col ( @strava_activity_columns ) {
        my $value = $sorted_activites[0]->{$col};
        if ( defined $value and $value =~ /^[0-9.]+$/ ) {
            $value = int($value + 0.5);
        }
        push @race_activity_row, $value;
    }

    my $sheet = $gs->get_sheet(title => $target_spreadsheet_name);
    my $sheet_prop = $sheet->{properties};

    push @requests, {
        pasteData => {
            coordinate => {
                sheetId     => $sheet_prop->{sheetId},
                rowIndex    => $current_row,
                columnIndex => $strava_gsheet_column_index_start,
            },
            data => $gs->to_csv(@race_activity_row),
            type => 'PASTE_NORMAL',
            delimiter => ',',
        },
    };
}

exit unless scalar @requests;

($content, $res) = $gs->request(
    POST => ':batchUpdate',
    {
        requests => \@requests,
    },
);

if ( $res and $res->code == 200 ) {
    printf("\nUpdated Google Sheet\n");
}
else {
    use Data::Dumper;
    warn sprintf("Error updating Google Sheet: '%s'\n", Dumper $res);
}

__END__

=pod

=head1 DESCRIPTION

Processes a given race day of the Google Sheet based race calendar and looks up potential rider participations
from Strava activities of signed up team members.

If found, activity metadata is stored in a tab a the Google Sheet race calendar.

=head1 USAGE

    perl update_teamcalendar_results_from_strava.pl --tokendir=DIRECTORY_WHERE_STRAVA_OAUTH_TOKENFILES_RESIDE --racedaydate='2022-05-12' \
        --client_id=GCLIENTIED \
        --client_secret=GCLIENTSECRET \
        --refresh_token=GCLIENTREFRESH_TOKEN \
        --spreadsheet_id=IDOFGSHEETWITHRACES

=cut
