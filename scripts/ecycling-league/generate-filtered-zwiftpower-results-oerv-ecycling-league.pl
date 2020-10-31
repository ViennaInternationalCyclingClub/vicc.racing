#!/usr/bin/perl

use strict;
use warnings;
use feature ':5.14';
use utf8;

use CGI::Simple;
use Text::CSV_XS ();
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use LWP::UserAgent ();
use Cpanel::JSON::XS ();
use HTML::Entities;
use Encode;
use Number::Format;
use List::MoreUtils qw(first_index);

my $zp_live_url_pattern = 'https://zwiftpower.com/json.php?t=live&id=%d';
my $zp_filtered_url_pattern = 'https://zwiftpower.com/cache3/results/%d_view.json?_=' . localtime();
my $zp_primes_url_pattern = 'https://www.zwiftpower.com/api3.php?do=event_primes&zid=%d&_=' . localtime();
my $zp_sprints_and_koms_url_pattern = 'https://zwiftpower.com/api3.php?do=event_sprints&zid=%d&_=' . localtime();

my $aktive_licenses = 'AktiveLizenzen.csv';
my $aktive_bikecards = 'AktiveBikecards.csv';
my $realname_mapping_file = 'realname_mapping.csv';

my @result_csv_field_order = (
    'eliga_category_position', 'position', 'last_name', 'first_name', 'zwift_category', 'eliga_category', 'kategorie national',
    'uciid', 'jahrgang', 'nationalität', 'club', 'race_time_formatted',
    'eliga_category_timegap', 'wkg', 'race_time', 'male', 'fin', 'dq', 'avg_hr', 'flag',
    'filtered_by_zwiftpower', 'normalized_name', 'full_name', 'primes_points',
    'sprints_and_koms_points-ELITE M', 'sprints_and_koms_points-ELITE W', 'sprints_and_koms_points-JUNIORS M', 'sprints_and_koms_points-JUNIORS W',
    'sprints_and_koms_points-U15ujuenger',
);

binmode( STDOUT, ':encoding(UTF-8)' );

my $q = CGI::Simple->new;
my $zpid = $q->param( 'zpid' );

# Depending on the type of race, we need to decide whether "finished" is coming from the live API endpoint with "fin:1"
# or it is enough if a rider is the final ZP result list
our $in_resultlist_is_finished = 1;

our @relevant_primes;
our $primes_bonus_points = $q->param( 'primes_bonus_points' );
$primes_bonus_points ||= 25;
my $rprimes = $q->param( 'relevant_primes' );
if ( defined $rprimes and length $rprimes) {
    @relevant_primes = split(',', $rprimes);
}
else {
    @relevant_primes = qw(4 8 12);
}
our $relevant_banner = $q->param( 'relevant_banner' );

my $sprints_and_koms = $q->param( 'sprints_and_koms' );
my @zp_sprints_koms = (
    'Main Sprint',
    'Box Hill',
    'Forward Sprint',
    'Second Sprint',
    'Reverse KOM',
    'Forward KOM',
    'Reverse Sprint',
    'Volcano Climb',
    'Volcano Circuit',
    'Alpe du Zwift',
    'Jungle Circuit',
    'Forward Epic',
    'Reverse Epic',
    'London Loop',
    'Fox Hill',
    'Leith Hill',
    'Keith Hill',
    'UCI Lap',
    'Libby Hill',
    '23rd Street',
    'NY Climb Forward',
    'Central Park Loop',
    'NY Sprint',
    'NY Climb Reverse',
    'NY Sprint 2',
    'Central Park Reverse',
    'Fuego Flats Short',
    'Fuego Flats Long',
    'TT Lap',
    'Titans Grove Reverse',
    'Titans Grove Forward',
    'Yorkshire KOM Forward',
    'Yorkshire Sprint Forward',
    'Yorkshire UCI Forward',
    'Yorkshire KOM Reverse',
    'Yorkshire Sprint Reverse',
    'Yorkshire UCI Reverse',
    'Crit City Lap',
    'Crit City Sprint',
    'Reverse Sprint 2',
    'Reverse UCI',
    'Reverse 23rd Street',
    'Aqueduc KOM',
    'Petit KOM',
    'VenTop',
    'Marina Sprint Rev',
    'Pave Sprint Rev',
    'Ballon Sprint',
    'Aqueduc KOM Rev',
    'Pave Sprint',
    'Marina Sprint',
    'Ballon Sprint Rev',
);

our @sprints_and_koms_ids;
if ( defined $sprints_and_koms ) {
    my @sprints_and_koms_names = split(',', $sprints_and_koms);
    foreach my $name ( @sprints_and_koms_names ) {
        my $index = first_index { $_ eq $name } @zp_sprints_koms;
        push( @sprints_and_koms_ids, $index + 1 ) if defined $index;
    }
}

my $csv = Text::CSV_XS->new( { auto_diag => 1, binary => 1 } );
my $json = Cpanel::JSON::XS->new();

my $ua = LWP::UserAgent->new(timeout => 10, ssl_opts => { verify_hostname => 0, SSL_verify_mode => SSL_VERIFY_NONE, });
$ua->agent('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4093.3 Safari/537.36');
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

if ( not (defined $zpid and length $zpid and $zpid =~ /^\d+$/ ) ) {
    print $q->header( -status => 200, -content_type => 'text/html; charset=utf-8' );
    print <<EOS;
<html><head><title>OERV eLiga ZwiftPower Results</title><style>body {font-family: Arial, Helvetica, sans-serif; } div, label, input { font-size: 1.5em; }</style></head>
    <body>
        <h1>ÖRV eLiga ZwiftPower Results</h1>
        <div style="margin-top: 50px; padding: 10px; border: 1px solid black;">
            <form action="$ENV{SCRIPT_NAME}">
                <label for="zpid">ZwiftPower RaceID</label>:
                <input type="number" name="zpid" min="1" max="999999" required="required" size="7" value=""/>
                &#xa0;<input type="submit" value="Abfragen" />
            </form>
        </div>
    </div>
    </body>
</html>
EOS
}
else {
    my $json_url = sprintf($zp_live_url_pattern, $zpid);
    my $json_filtered_url = sprintf($zp_filtered_url_pattern, $zpid);

    my $zwift_power_results = fetch_json($json_url);
    my $zwift_power_results_filtered = fetch_json($json_filtered_url);
    # some races *may* not have live results. Fallback to the filtered ones in case
    if ( not defined $zwift_power_results ) {
        $zwift_power_results = $zwift_power_results_filtered;
    }
    my %filtered;
    foreach my $record ( @{$zwift_power_results_filtered->{data}} ) {
        $filtered{normalize_name($record->{name})} = $record;
    }

    my %fastest_per_eliga_category;
    my %eliga_category_positions;

    my @output_rows;
    foreach my $record ( @{$zwift_power_results->{data}} ) {
        my $normalized_name = normalize_name($record->{name});
        my $full_row;
        if ( exists $licenses->{$normalized_name} or
             (exists $realname_mapping->{$record->{name}} and exists $licenses->{$realname_mapping->{$record->{name}}}) ) {
            $full_row = record_to_row($record,$normalized_name,\%filtered);
            my @license_fields_to_add = ('jahrgang', 'uciid', 'kategorie national', 'nationalität', 'kategorie (uci)', 'geschlecht');

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
        elsif ( exists $bike_cards->{$normalized_name} or
             ( exists $realname_mapping->{$record->{name}} and exists $bike_cards->{$realname_mapping->{$record->{name}}}) ) {
            $full_row = record_to_row($record,$normalized_name,\%filtered);

            if ( not exists $bike_cards->{$normalized_name} ) {
                $normalized_name = $realname_mapping->{$record->{name}};
            }

            $full_row = {
                %$full_row,
                club => $bike_cards->{$normalized_name}->{'bike card'},
                'kategorie national' => $bike_cards->{$normalized_name}->{'bike card'},
                last_name => $bike_cards->{$normalized_name}->{'nachname'},
                first_name => $bike_cards->{$normalized_name}->{'vorname'},
            };
        }
        elsif ( $record->{flag} eq 'at' ) {
            $full_row = record_to_row($record,$normalized_name,\%filtered);
            $full_row = {
                %$full_row,
                club => '',
                last_name => decode_entities($full_row->{name}),
                first_name => '',
            };
        }

        if ( defined $full_row ) {
            $full_row->{normalized_name} = $normalized_name;
            $full_row->{full_name} = $full_row->{last_name} . ' ' . $full_row->{first_name};
            $full_row->{eliga_category} = resolve_category( $full_row );
            $full_row->{filtered_by_zwiftpower} = 1 unless exists $filtered{$normalized_name};
            my $eliga_category_position;
            if ( not $full_row->{fin} and length $full_row->{club} ) {
                $full_row->{eliga_category_position} = 'DNF';
            }
            elsif ( length $full_row->{club} == 0 ) {
                $full_row->{eliga_category_position} = 'UNCATEGORIZED';
            }
            # Do not require HRM for Juniors
            elsif ( not $full_row->{avg_hr} and not $full_row->{eliga_category} =~ /^JUNIORS/
                # white-list riders which proved they actually have ridden with HR data
                and not $full_row->{normalized_name} =~ /(konczer|gratzer|janecka|brunhofer|daniel hager)/ ) {
                $full_row->{eliga_category_position} = 'DSQ';
                $full_row->{position} = 'DSQ';
            }
            else {
                $full_row->{eliga_category_position} = ++$eliga_category_positions{$full_row->{eliga_category}};
            }
            if ( not defined $fastest_per_eliga_category{$full_row->{eliga_category}} and $full_row->{eliga_category_position} =~ /^\d+$/ ) {
                $fastest_per_eliga_category{$full_row->{eliga_category}} = $full_row->{race_time};
                $full_row->{eliga_finisher} = 1;
            }
            elsif ( $full_row->{eliga_category_position} =~ /^\d+$/ ) {
                $full_row->{eliga_finisher} = 1;
                $full_row->{eliga_category_timegap} = format_ms( $full_row->{race_time} - $fastest_per_eliga_category{$full_row->{eliga_category}} );
            }

            push @output_rows, $full_row;
        }
    }

    #print $q->header( -status => 200, -content_type => 'text/plain; charset=utf-8', -expires => '0' );
    print $q->header( -status => 200, -content_type => 'text/csv; charset=utf-8', -expires => '0', -content_disposition => 'inline; filename=results.csv', );
    $csv->say(*STDOUT, \@result_csv_field_order);
    foreach my $row ( @output_rows ) {
        calculate_primes_points( \@output_rows, $row );
        calculate_sprints_koms_points( \@output_rows, $row );
        $csv->say(*STDOUT, [( map {$row->{$_}} @result_csv_field_order)]);
    }
}

state %all_eliga_riders;

exit 0;

sub calculate_sprints_koms_points {
    my ($all_rows, $full_row) = @_;

    return unless scalar @sprints_and_koms_ids;

    my $riders_per_category_sorted = _setup_sprints_and_koms($all_rows);

    my $bonus_points = 0;
    foreach my $sprint_or_kom ( @sprints_and_koms_ids ) {
        if ( $riders_per_category_sorted->{$sprint_or_kom}{$full_row->{eliga_category}}->[0] eq $full_row->{normalized_name} ) {
            $bonus_points += $primes_bonus_points;
        }
    }

    $full_row->{"sprints_and_koms_points-" . $full_row->{eliga_category}} = $bonus_points;
    return 1;
}

sub _setup_sprints_and_koms {
    my ($all_rows) = @_;

    state %riders_per_category_sorted;
    return \%riders_per_category_sorted if scalar keys %riders_per_category_sorted;

    foreach my $row (@$all_rows) {
        $all_eliga_riders{$row->{normalized_name}} = $row if defined $row->{eliga_category};
    }

    state $zwift_sprints_and_koms_results = fetch_json(sprintf($zp_sprints_and_koms_url_pattern, $zpid));
    state %all_eliga_riders_by_category;
    foreach my $rider ( @{$zwift_sprints_and_koms_results->{data}} ) {
        my $current_rider = normalize_name($rider->{name});
        if ( exists $all_eliga_riders{$current_rider} and $all_eliga_riders{$current_rider}->{eliga_finisher} ) {
            $all_eliga_riders_by_category{$all_eliga_riders{$current_rider}->{eliga_category}}->{$current_rider} = $rider->{msec};
        }
    }

    foreach my $sprint_or_kom ( @sprints_and_koms_ids ) {
        foreach my $eliga_category ( keys %all_eliga_riders_by_category ) {
            my @sorted_riders = sort {
                    $all_eliga_riders_by_category{$eliga_category}->{$a}->{$sprint_or_kom} <=> $all_eliga_riders_by_category{$eliga_category}->{$b}->{$sprint_or_kom}
                } keys %{$all_eliga_riders_by_category{$eliga_category}};
            $riders_per_category_sorted{$sprint_or_kom}{$eliga_category} = \@sorted_riders;
        }
    }

    return \%riders_per_category_sorted;
}

sub calculate_primes_points {
    my ($all_rows, $full_row) = @_;

    if ( not $relevant_banner ) {
        $full_row->{primes_points} = 0;
        return;
    }

    foreach my $row (@$all_rows) {
        $all_eliga_riders{$row->{normalized_name}} = $row if defined $row->{eliga_category};
    }

    state $zwift_power_primes_results = fetch_json(sprintf($zp_primes_url_pattern, $zpid));
    my @relevant_banners = grep { $_->{name} eq $relevant_banner } @{$zwift_power_primes_results->{data}};
    my @prime_points = qw(5 3 2 1);
    my @riders = map { "rider_$_" } (1..10);
    my %eliga_riders_with_points;
    foreach my $prime ( @relevant_primes ) {
        my $i = 0;
        foreach my $rider (@riders) {
            last if $i == scalar(@prime_points) - 1;
            my $current_rider = normalize_name($relevant_banners[$prime-1]->{$rider}->{name});
            if ( exists $all_eliga_riders{$current_rider} ) {
                $eliga_riders_with_points{$current_rider} = $prime_points[$i++];
            }
        }
    }

    my @sorted_riders = reverse sort { $eliga_riders_with_points{$a} <=> $eliga_riders_with_points{$b} } keys %eliga_riders_with_points;
    if ( $sorted_riders[0] eq $full_row->{normalized_name} ) {
        $full_row->{primes_points} = $primes_bonus_points;
    }
    else {
        $full_row->{primes_points} = 0;
    }

    return 1;
}

sub resolve_category {
    my ($full_row) = @_;

    if ( defined $full_row->{'kategorie (uci)'}
        and ($full_row->{'kategorie (uci)'} eq 'YOUTH' and $full_row->{'kategorie national'} =~ /\bU1(3|5)\b/ ) ) {
        return 'U15ujuenger';
    }
    elsif ( defined $full_row->{'kategorie (uci)'}
        and ($full_row->{'kategorie (uci)'} eq 'JUNIORS' or $full_row->{'kategorie (uci)'} eq 'YOUTH' ) ) {
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
    my ($record,$normalized_name,$filtered) = @_;

    my @one_to_ones = qw(flag male dq grp name);
    # state $number_format = Number::Format->new(
    #     -thousands_sep   => '.',
    #     -decimal_point   => ',',);
    my $position;
    my $fin;
    if ( $in_resultlist_is_finished and $filtered->{$normalized_name}->{pos} ) {
        $position = $filtered->{$normalized_name}->{pos};
        $fin = 1;
    }
    elsif ( $record->{fin} ) {
        $position = $record->{position};
        $fin = 1;
    }
    else {
        $position = 'DNF';
    }

    my $race_time = $record->{race_time}->[0];
    $race_time ||= ($record->{time}->[0] * 1000);
    my $race_time_formatted = format_ms($race_time);

    return {
        race_time => $race_time,
        race_time_formatted => $race_time_formatted,
        avg_hr => $filtered->{$normalized_name}->{avg_hr}->[0] || $record->{ahr}->[0],
        #wkg => $number_format->format_number($record->{wkg}->[0]),
        wkg => $record->{wkg}->[0] || $filtered->{$normalized_name}->{avg_wkg}->[0],
        position => $position,
        fin => $fin,
        zwift_category => $filtered->{$normalized_name}->{category},
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

    warn "Fetching $url";
    my $response = $ua->get($url);
    if ( not $response->is_success ) {
        print $q->header( -status => 500 );
        printf('Could not fetch url "%s": "%s"', $url, $response->status_line);
        exit;
    }

    my $content = $response->decoded_content;
    return unless $content;
    return $json->decode($content);
}

sub normalize_name {
    my ($name) = @_;

    my %charmap = ("ä" => "ae", "ü" => "ue", "ö" => "oe", "ß" => "ss" );
    state $charmap_regex = join ("|", keys(%charmap));
    $name = lc decode_entities($name);
    $name =~ s/($charmap_regex)/$charmap{$1}/g;
    $name =~ s/[\[\(-,;_].*$//g;
    $name =~ s/[^a-z ]//g;
    $name =~ s/^\s+|\s+$//g;

    return $name;
}

