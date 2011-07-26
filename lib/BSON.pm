package BSON;

use 5.008;
use strict;
use warnings;

use base 'Exporter';
our @EXPORT_OK = qw/encode decode/;

our $VERSION = 0.02;

use Carp;
use Tie::IxHash;

use BSON::Time;
use BSON::Timestamp;
use BSON::MinKey;
use BSON::MaxKey;
use BSON::Binary;
use BSON::ObjectId;
use BSON::Code;
use BSON::Bool;

# Maximum size of a BSON record
our $MAX_SIZE = 16 * 1024 * 1024;

#<<<
my $int_re     = qr/^(?:(?:[+-]?)(?:[0123456789]+))$/;
my $doub_re    = qr/^(?:(?i)(?:[+-]?)(?:(?=[0123456789]|[.])(?:[0123456789]*)(?:(?:[.])(?:[0123456789]{0,}))?)(?:(?:[E])(?:(?:[+-]?)(?:[0123456789]+))|))$/;
my $min_int_32 = -2**32 / 2;
my $max_int_32 = 2**32 / 2 - 1;
my $min_int_64 = -2**64 / 2;
my $max_int_64 = 2**64 / 2 - 1;
#>>>

sub e_name {
    pack 'CZ*', @_;
}

sub string {
    pack 'V/Z*', shift;
}

sub s_arr {
    my ( $key, $value ) = @_;
    my $i = 0;
    tie( my %h, 'Tie::IxHash' );
    %h = map { $i++ => $_ } @$value;
    e_name( 0x04, $key ) . encode( \%h );
}

sub s_int {
    my ( $key, $value ) = @_;
    if ( $value > $max_int_64 || $value < $min_int_64 ) {
        confess("MongoDB can only handle 8-byte integers");
    }
    return $value > $max_int_32 || $value < $min_int_32
      ? e_name( 0x12, $key ) . pack( 'q', $value )
      : e_name( 0x10, $key ) . pack( 'l', $value );
}

sub s_re {
    my ( $key, $value ) = @_;
    $value =~ s/^\(\?\^//;
    $value =~ s/\)$//;
    my ( $opt, $re ) = split( /:/, $value, 2 );
    my @o = sort grep /^(i|m|x|l|s|u)$/, split( //, $opt );
    e_name( 0x0B, $key ) . pack( 'Z*', $re ) . pack( 'a*', @o ) . "\0";
}

sub s_dt {
    my ( $key, $value ) = @_;
    e_name( 0x09, $key ) . pack( 'q', $value->epoch * 1000 );
}

sub s_code {
    my ( $key, $value ) = @_;
    if ( ref $value->scope eq 'HASH' ) {
        my $scope = encode( $value->scope );
        my $code  = string( $value->code );
        my $len   = 4 + length($scope) + length($code);
        return e_name( 0x0F, $key ) . pack( 'L', $len ) . $code . $scope;
    }
    else {
        return e_name( 0x0D, $key ) . string( $value->code );
    }
}

sub s_hash {
    my $doc  = shift;
    my $bson = '';
    while ( my ( $key, $value ) = each %$doc ) {

        # Null
        if ( !defined $value ) {
            $bson .= e_name( 0x0A, $key );
        }

        # Array
        elsif ( ref $value eq 'ARRAY' ) {
            $bson .= s_arr( $key, $value );
        }

        # Document
        elsif ( ref $value eq 'HASH' ) {
            $bson .= e_name( 0x03, $key ) . encode($value);
        }

        # Regex
        elsif ( ref $value eq 'Regexp' ) {
            $bson .= s_re( $key, $value );
        }

        # ObjectId
        elsif ( ref $value eq 'BSON::ObjectId' ) {
            $bson .= e_name( 0x07, $key ) . $value->value;
        }

        # Datetime
        elsif ( ref $value eq 'BSON::Time' ) {
            $bson .= e_name( 0x09, $key ) . pack( 'q', $value->value );
        }

        # Timestamp
        elsif ( ref $value eq 'BSON::Timestamp' ) {
            $bson .=
              e_name( 0x11, $key )
              . pack( 'LL', $value->increment, $value->seconds );
        }

        # MinKey
        elsif ( ref $value eq 'BSON::MinKey' ) {
            $bson .= e_name( 0xFF, $key );
        }

        # MaxKey
        elsif ( ref $value eq 'BSON::MaxKey' ) {
            $bson .= e_name( 0x7F, $key );
        }

        # Binary
        elsif ( ref $value eq 'BSON::Binary' ) {
            $bson .= e_name( 0x05, $key ) . $value;
        }

        # Code
        elsif ( ref $value eq 'BSON::Code' ) {
            $bson .= s_code( $key, $value );
        }

        # Boolean
        elsif ( ref $value eq 'BSON::Bool' ) {
            $bson .= e_name( 0x08, $key ) . ( $value ? "\1" : "\0" );
        }

        # Int (32 and 64)
        elsif ( $value =~ $int_re ) {
            $bson .= s_int( $key, $value );
        }

        # Double
        elsif ( $value =~ $doub_re ) {
            $bson .= e_name( 0x01, $key ) . pack( 'd', $value );
        }

        # String
        else {
            $bson .= e_name( 0x02, $key ) . string($value);
        }
    }
    return $bson;
}

sub d_hash {
    my $bson = shift;
    my %opt  = @_;
    my %hash = ();
    if ( $opt{ixhash} ) { tie( %hash, 'Tie::IxHash' ) }
    while ($bson) {
        my $value;
        ( my $type, my $key, $bson ) = unpack( 'CZ*a*', $bson );

        # Double
        if ( $type == 0x01 ) {
            ( $value, $bson ) = unpack( 'da*', $bson );
        }

        # String and Symbol
        elsif ( $type == 0x02 || $type == 0x0E ) {
            ( my $len, $value, $bson ) = unpack( 'LZ*a*', $bson );
        }

        # Document and Array
        elsif ( $type == 0x03 || $type == 0x04 ) {
            my $len = unpack( 'L', $bson );
            $value = decode( substr( $bson, 0, $len ), %opt );
            if ( $type == 0x04 ) {
                my @a =
                  map { $value->{$_} } ( 0 .. scalar( keys %$value ) - 1 );
                $value = \@a;
            }
            $bson = substr( $bson, $len, length($bson) - $len );
        }

        # Binary
        elsif ( $type == 0x05 ) {
            my $len = unpack( 'L', $bson ) + 5;
            my @a = unpack( 'LCa*', substr( $bson, 0, $len ) );
            $value = BSON::Binary->new( $a[2], $a[1] );
            $bson = substr( $bson, $len, length($bson) - $len );
        }

        # ObjectId
        elsif ( $type == 0x07 ) {
            ( my $oid, $bson ) = unpack( 'a12a*', $bson );
            $value = BSON::ObjectId->new($oid);
        }

        # Boolean
        elsif ( $type == 0x08 ) {
            ( my $bool, $bson ) = unpack( 'Ca*', $bson );
            $value = BSON::Bool->new($bool);
        }

        # Datetime
        elsif ( $type == 0x09 ) {
            ( my $dt, $bson ) = unpack( 'qa*', $bson );
            $value = BSON::Time->new( int( $dt / 1000 ) );
        }

        # Null
        elsif ( $type == 0x0A ) {
            $value = undef;
        }

        # Regex
        elsif ( $type == 0x0B ) {
            ( my $re, my $op, $bson ) = unpack( 'Z*Z*a*', $bson );
            $value = eval "qr/$re/$op";
        }

        # Code
        elsif ( $type == 0x0D ) {
            ( my $len, my $code, $bson ) = unpack( 'LZ*a*', $bson );
            $value = BSON::Code->new($code);
        }

        # Code with scope
        elsif ( $type == 0x0F ) {
            my $len = unpack( 'L', $bson );
            my @a = unpack( 'L2Z*a*', substr( $bson, 0, $len ) );
            $value = BSON::Code->new( $a[2], decode( $a[3], %opt ) );
            $bson = substr( $bson, $len, length($bson) - $len );
        }

        # Int32
        elsif ( $type == 0x10 ) {
            ( $value, $bson ) = unpack( 'la*', $bson );
        }

        # Timestamp
        elsif ( $type == 0x11 ) {
            ( my $sec, my $inc, $bson ) = unpack( 'LLa*', $bson );
            $value = BSON::Timestamp->new( $inc, $sec );
        }

        # Int64
        elsif ( $type == 0x12 ) {
            ( $value, $bson ) = unpack( 'qa*', $bson );
        }

        # MinKey
        elsif ( $type == 0xFF ) {
            $value = BSON::MinKey->new;
        }

        # MaxKey
        elsif ( $type == 0x7F ) {
            $value = BSON::MaxKey->new;
        }

        # ???
        else {
            croak "Unsupported type $type";
        }

        $hash{$key} = $value;
    }
    return \%hash;
}

sub encode {
    my $doc = shift;
    my $r   = s_hash($doc);
    return pack( 'L', length($r) + 5 ) . $r . "\0";
}

sub decode {
    my $bson = shift;
    my $len = unpack( 'L', $bson );
    if ( length($bson) != $len ) {
        croak("Incorrect length of the bson string");
    }
    return d_hash( substr( $bson, 4, -1 ), @_ );
}

1;

__END__

=head1 NAME

BSON - Pure Perl implementation of MongoDB's BSON serialization

=head1 VERSION

Version 0.02

=head1 SYNOPSIS

    use BSON qw/encode decode/;

    my $document = {
        _id    => BSON::ObjectId->new,
        date   => BSON::Time->new,
        name   => 'James Bond',
        age    => 45,
        amount => 24587.45,
        badass => BSON::Bool->true
    };

    my $bson = encode( $document );
    my $doc2 = decode( $bson, %options );

=head1 DESCRIPTION 

This module implements BSON serialization and deserialization as described at
L<http://bsonspec.org>. BSON is the primary data representation for MongoDB.

=head1 EXPORT

The module does not export anything. You have to request C<encode> and/or
C<decode> manually.

    use BSON qw/encode decode/;
    
=head1 SUBROUTINES

=head2 encode

Takes a hashref and returns a BSON string.

    my $bson = encode({ bar => 'foo' });

=head2 decode

Takes a BSON string and returns a hashref.

    my $hash = decode( $bson, ixhash => 1 );

The options after C<$bson> are optional and they can be any of the following:

=head3 options

=over

=item 1

ixhash => 1|0

If set to 1 C<decode> will return a L<Tie::IxHash> ordered hash. Otherwise,
a regular unordered hash will be returned. Turning this option on entails a 
significant speed penalty as Tie::IxHash is slower than a regular Perl hash.
The default value for this option is 0.

=back

=head1 THREADS

This module is thread safe.

=head1 SEE ALSO

L<BSON::Time>, L<BSON::ObjectId>, L<BSON::Code>,
L<BSON::Binary>, L<BSON::Bool>, L<BSON::MinKey>, L<BSON::MaxKey>,
L<BSON::Timestamp>, L<Tie::IxHash>, L<MongoDB>

=head1 AUTHOR

minimalist, C<< <minimalist at lavabit.com> >>

=head1 BUGS

Bug reports and patches are welcome. Reports which include a failing 
Test::More style test are helpful and will receive priority.

=head1 DEVELOPMENT

The source code of this module is available on GitHub:
L<https://github.com/naturalist/Perl-BSON>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 minimalist.

This program is free software; you can redistribute it and/or modify 
it under the terms as perl itself.

=cut