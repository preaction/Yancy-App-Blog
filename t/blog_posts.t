
use v5.30;
use warnings;
use experimental qw( postderef signatures );
use Test::More;
use Test::Mojo;
use FindBin qw( $Bin );

require "$Bin/../myapp.pl";
my $t = Test::Mojo->new;

$t->get_ok( '/' )->status_is( 200 );

done_testing;
