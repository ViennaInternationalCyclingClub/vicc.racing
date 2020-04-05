#!/usr/bin/perl

use strict;
use warnings;
use feature ':5.14';
use utf8;

use Text::CSV_XS ();
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use LWP::UserAgent ();
use Cpanel::JSON::XS ();
use DateTime::Duration;
use DateTime::Format::Duration;
use HTML::Entities;
use Encode;
use Number::Format;

# live: https://zwiftpower.com/json.php?t=live&id=439676
my $json_url = 'file:zwiftpower-results-first-oerv-ecycling-league-439676.json';
# filtered: https://zwiftpower.com/cache3/results/439676_view.json
my $json_filtered_url = 'file:zwiftpower-results-first-oerv-ecycling-league-439676-filtered.json';
my $aktive_licenses = 'AktiveLizenzen.csv';
my $aktive_bikecards = 'AktiveBikecards.csv';
my $realname_mapping_file = 'realname_mapping.csv';

my @result_csv_field_order = (
    'eliga_category_position', 'position', 'last_name', 'first_name', 'zwift_category', 'eliga_category', 'kategorie national',
    'uciid', 'jahrgang', 'nationalität', 'club', 'race_time', 'race_time_formatted',
    'eliga_category_timegap', 'wkg', 'male', 'fin', 'dq', 'avg_hr', 'flag',
    'filtered_by_zwiftpower', 'normalized_name',
);

binmode( STDOUT, ':encoding(UTF-8)' );

my $csv = Text::CSV_XS->new( { auto_diag => 1, binary => 1 } );
my $json = Cpanel::JSON::XS->new();

my $ua = LWP::UserAgent->new(timeout  => 1, ssl_opts => { verify_hostname => 0, SSL_verify_mode => SSL_VERIFY_NONE, });
$ua->default_header('Accept' => 'application/json');

my $licenses;
open my $fh_l, "<:encoding(utf8)", $aktive_licenses or die "$aktive_licenses: $!";
$csv->header ($fh_l);
while (my $row = $csv->getline_hr($fh_l)) {
    $licenses->{normalize_name($row->{vorname} . ' ' . $row->{name})} = $row;
}
close $fh_l;

my $bike_cards;
open my $fh_b, "<:encoding(utf8)", $aktive_bikecards or die "$aktive_bikecards: $!";
$csv->header($fh_b);
while (my $row = $csv->getline_hr($fh_b)) {
    $bike_cards->{normalize_name($row->{vorname} . ' ' . $row->{nachname})} = $row;
}
close $fh_b;

my $realname_mapping;
open my $fh_r, "<:encoding(utf8)", $realname_mapping_file or die "$realname_mapping_file: $!";
$csv->header($fh_r);
while (my $row = $csv->getline_hr($fh_r)) {
    $realname_mapping->{$row->{zwift_power_name}} = $row->{normalized_name};
}
close $fh_r;

my $zwift_power_results = fetch_json($json_url);
my $zwift_power_results_filtered = fetch_json($json_filtered_url);
my %filtered_names;
foreach my $record ( @{$zwift_power_results_filtered->{data}} ) {
    $filtered_names{normalize_name($record->{name})} = 1;
}

my %fastest_per_eliga_category;
my %eliga_category_positions;

$csv->say(*STDOUT, \@result_csv_field_order);
foreach my $record ( @{$zwift_power_results->{data}} ) {
    my $normalized_name = normalize_name($record->{name});
    my $full_row;
    if ( exists $licenses->{$normalized_name} or
         (exists $realname_mapping->{$record->{name}} and exists $licenses->{$realname_mapping->{$record->{name}}}) ) {
        $full_row = record_to_row($record);
        state @license_fields_to_add = ('jahrgang', 'uciid', 'kategorie national', 'nationalität', 'kategorie (uci)', 'geschlecht');

        if ( not exists $licenses->{$normalized_name} ) {
            $normalized_name = $realname_mapping->{$record->{name}};
        }

        $full_row = {
            %$full_row,
            club => $licenses->{$normalized_name}->{'team'}
                ? $licenses->{$normalized_name}->{'team'}
                : $licenses->{$normalized_name}->{'verein'},
            last_name => $licenses->{$normalized_name}->{'name'},
            first_name => $licenses->{$normalized_name}->{'vorname'},
            map { $_ => $licenses->{$normalized_name}->{$_} } @license_fields_to_add,
        };
    }
    elsif ( exists $bike_cards->{$normalized_name} ) {
        $full_row = record_to_row($record);
        $full_row = {
            %$full_row,
            club => $bike_cards->{$normalized_name}->{'bike card'},
            last_name => $bike_cards->{$normalized_name}->{'nachname'},
            first_name => $bike_cards->{$normalized_name}->{'vorname'},
        };
    }
    elsif ( $record->{flag} eq 'at' ) {
        $full_row = record_to_row($record);
        $full_row = {
            %$full_row,
            club => '',
            last_name => decode_entities($full_row->{name}),
            first_name => '',
        };
    }

    if ( defined $full_row ) {
        $full_row->{normalized_name} = $normalized_name;
        $full_row->{eliga_category} = resolve_category( $full_row );
        $full_row->{filtered_by_zwiftpower} = 1 unless exists $filtered_names{$normalized_name};
        my $eliga_category_position;
        if ( not $full_row->{fin} ) {
            $full_row->{eliga_category_position} = 'DNF';
        }
        elsif ( not $full_row->{avg_hr} ) {
            $full_row->{eliga_category_position} = 'DSQ';
        }
        elsif ( length $full_row->{club} == 0 ) {
            $full_row->{eliga_category_position} = 'UNCATEGORIZED';
        }
        else {
            $full_row->{eliga_category_position} = ++$eliga_category_positions{$full_row->{eliga_category}};
        }
        if ( not defined $fastest_per_eliga_category{$full_row->{eliga_category}} and $full_row->{eliga_category_position} =~ /^\d+$/ ) {
            $fastest_per_eliga_category{$full_row->{eliga_category}} = $full_row->{race_time};
        }
        elsif ( $full_row->{eliga_category_position} =~ /^\d+$/ ) {
            $full_row->{eliga_category_timegap} = format_ms( $full_row->{race_time} - $fastest_per_eliga_category{$full_row->{eliga_category}} );
        }

        $csv->say(*STDOUT, [( map {$full_row->{$_}} @result_csv_field_order)]);
    }
}

exit 0;

sub resolve_category {
    my ($full_row) = @_;

    if ( defined $full_row->{'kategorie (uci)'}
        and ($full_row->{'kategorie (uci)'} eq 'YOUTH' or $full_row->{'kategorie (uci)'} eq 'JUNIORS') ) {
        if ( $full_row->{'geschlecht'} eq 'M' ) {
            return 'JUNIORS M';
        }
        else {
            return 'JUNIORS W';
        }
    }
    elsif ( $full_row->{'male'} ) {
        return 'ELITE M';
    }
    else {
        return 'ELITE W';
    }
}

sub record_to_row {
    my ($record) = @_;

    my @one_to_ones = qw(flag male fin dq grp name);
    # state $number_format = Number::Format->new(
    #     -thousands_sep   => '.',
    #     -decimal_point   => ',',);

    my %zwift_category_mapping = (
        699676 => 'A',
        699677 => 'B',
        699678 => 'C',
        699679 => 'D',
    );

    return {
        race_time => $record->{race_time}->[0],
        race_time_formatted => format_ms($record->{race_time}->[0]),
        avg_hr => $record->{ahr}->[0],
        #wkg => $number_format->format_number($record->{wkg}->[0]),
        wkg => $record->{wkg}->[0],
        position => $record->{fin} ? $record->{position} : 'DNF',
        zwift_category => $zwift_category_mapping{$record->{grp}},
        map { $_ => $record->{$_} } @one_to_ones,
    };
}

sub format_ms {
    my ($race_time_ms) = @_;

    return sprintf("%02d:%02d:%02d.%03d",
        ($race_time_ms/1000)/3600,
        ($race_time_ms/1000)/60%60,
        ($race_time_ms/1000)%60,
        $race_time_ms%1000,
    );
}

sub fetch_json {
    my ($url) = @_;

    my $response = $ua->get($url);
    if ( not $response->is_success ) {
        die sprintf('Could not fetch url "%s": "%s"', $url, $response->status_line);
    }

    return $json->decode($response->decoded_content);
}

sub normalize_name {
    my ($name) = @_;

    state %charmap = ("ä" => "ae", "ü" => "ue", "ö" => "oe", "ß" => "ss" );
    state $charmap_regex = join ("|", keys(%charmap));
    $name = lc decode_entities($name);
    $name =~ s/($charmap_regex)/$charmap{$1}/g;
    $name =~ s/[\[\(-,;_].*$//g;
    $name =~ s/[^a-z ]//g;
    $name =~ s/^\s+|\s+$//g;

    return $name;
}