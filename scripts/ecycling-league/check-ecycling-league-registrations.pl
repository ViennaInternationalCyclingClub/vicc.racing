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

my $aktive_licenses = 'AktiveLizenzen.csv';
my $aktive_bikecards = 'AktiveBikecards.csv';
my $eliga_nennungen = 'ELigaNennungen.csv';
my $realname_mapping_file = 'realname_mapping.csv';

# For the league, next year's categories are used.
my %CATEGORY_FIXUP = (
    2008 => [ 'U15', 'YOUTH' ], # national, UCI
    2007 => [ 'U15', 'YOUTH' ],
    2006 => [ 'U17', 'YOUTH' ],
    2005 => [ 'U17', 'YOUTH' ],
    2004 => [ 'U19', 'JUNIORS' ],
    2003 => [ 'U19', 'JUNIORS' ],
    2002 => [ 'U23', 'U23' ],
    1998 => [ 'ELITE', 'ELITE' ],
);

binmode( STDOUT, ':encoding(UTF-8)' );

my $csv = Text::CSV_XS->new( { auto_diag => 1, binary => 1 } );
my $json = Cpanel::JSON::XS->new();

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

my $nennungen;
open my $fh_n, "<:encoding(utf8)", $eliga_nennungen or die "$eliga_nennungen: $!";
$csv->header($fh_n);
while (my $row = $csv->getline_hr($fh_n)) {
    $nennungen->{normalize_name($row->{firstname} . ' ' . $row->{lastname})} = $row;
}
close $fh_n;

my $realname_mapping;
open my $fh_r, "<:encoding(utf8)", $realname_mapping_file or die "$realname_mapping_file: $!";
$csv->header($fh_r);
while (my $row = $csv->getline_hr($fh_r)) {
    $realname_mapping->{$row->{zwift_power_name}} = $row->{normalized_name};
}
close $fh_r;

my %realname_mapping_reversed = reverse %$realname_mapping;

my @records;
foreach my $rider ( keys %$nennungen ) {
    my $record;
    if ( exists $licenses->{$rider} ) {
        $record = $licenses->{$rider};
        $record->{nachname} = $record->{name};
    }
    elsif ( exists $bike_cards->{$rider} ) {
        $record = $bike_cards->{$rider};
    }
    else {
        my $comment = $nennungen->{$rider}->{comment};
        if (defined $nennungen->{$rider}->{licence} and length $nennungen->{$rider}->{licence} == 11) {
            $comment .= ' Ausländische Lizenz ' . $nennungen->{$rider}->{licence} . '. Gültigkeit zu überprüfen';
        }
        push(@records, {
            nachname => $nennungen->{$rider}->{lastname},
            vorname => $nennungen->{$rider}->{firstname},
            eliga_category => 'NOAUTLICENSE_NOBIKECARD',
            club => $nennungen->{$rider}->{club},
            licence => $nennungen->{$rider}->{licence},
            email => $nennungen->{$rider}->{email},
            kommentar => $comment });
        next;
    }

    my ($jahrgang) = ($nennungen->{$rider}->{'dob'} =~ /\d\d\.\d\d\.(\d\d\d\d)/ );
    if ( exists $CATEGORY_FIXUP{$jahrgang} ) {
        $record->{'kategorie (uci)'} = $CATEGORY_FIXUP{$record->{'jahrgang'}}->[1];
    }
    $record->{eliga_category} = resolve_category( $record );
    push(@records, $record);
}

my @result_csv_field_order = qw(nachname vorname eliga_category club kommentar licence email);

$csv->say(*STDOUT, \@result_csv_field_order);
foreach my $row ( sort { $a->{nachname} cmp $b->{nachname} } @records ) {
    $csv->say(*STDOUT, [( map {$row->{$_}} @result_csv_field_order)]);
}

sub resolve_category {
    my ($full_row) = @_;

    my $category;
    if ( defined $full_row->{'kategorie (uci)'} ) {
        if ( $full_row->{'kategorie (uci)'} =~ /\A(?:ELITE|JUNIORS|YOUTH)\z/ ) {
            $category = $full_row->{'kategorie (uci)'};
        }
        elsif ( $full_row->{'kategorie (uci)'} eq 'MASTERS'
            or $full_row->{'kategorie national'} eq 'STRASSE AMATEURE' ) {
            $category = 'AMATEURE/MASTERS';
        }
        elsif ( $full_row->{'kategorie (uci)'} eq 'UNDER 23' ) {
            $category = 'ELITE';
        }
        else {
            $category = 'ELITE'; # Riders with UCI license but no rider license
        }
    }
    else {
        $category = 'BIKECARD';
    }

    return sprintf('%s', $category);
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

