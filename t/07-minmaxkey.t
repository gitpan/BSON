#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
use BSON;

my $k = BSON::MinKey->new;
isa_ok( $k, 'BSON::MinKey' );
$k = BSON::MaxKey->new;
isa_ok( $k, 'BSON::MaxKey' );
