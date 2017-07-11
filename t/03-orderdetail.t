use utf8;
use strict;
use warnings;

use open ':std', ':encoding(utf8)';
use Test::More;

use OpenCloset::Schema;
use OpenCloset::API::Order;
use OpenCloset::API::OrderDetail;

use lib 't/lib';
use Param::Order qw/order_param/;

my $db_opts = {
    dsn  => $ENV{OPENCLOSET_DATABASE_DSN}  || "dbi:mysql:opencloset:127.0.0.1",
    user => $ENV{OPENCLOSET_DATABASE_USER} || 'opencloset',
    password => $ENV{OPENCLOSET_DATABASE_PASS} // 'opencloset',
    quote_char        => q{`},
    mysql_enable_utf8 => 1,
    on_connect_do     => 'SET NAMES utf8',
    RaiseError        => 1,
    AutoCommit        => 1,
};

my $schema   = OpenCloset::Schema->connect($db_opts);
my $hostname = `hostname`;
my $username = $ENV{USER};

if ( $username eq 'opencloset' or $hostname =~ m/opencloset/ ) {
    plan skip_all => 'Do not run on service host';
}

my $order_api = OpenCloset::API::Order->new( schema => $schema );
my $api = OpenCloset::API::OrderDetail->new( schema => $schema );
ok( $api, 'OpenCloset::API::OrderDetail->new' );

my $order_param = order_param($schema);
$order_param->{user_id} = 2;
my $order = $schema->resultset('Order')->create($order_param);
my @codes = qw/0A001 0S003 0P001 0J001/;
$order_api->box2boxed( $order, \@codes );

my $details = $order->order_details( { stage => 0, clothes_code => { '!=' => undef } } );
my $detail = $details->next;
$detail->update( { price => 100_000 } );
$detail = $api->update_price( $detail, 50_000 );
ok( $detail, 'update_price' );
is( $detail->price,       50_000, 'update_price' );
is( $detail->final_price, 50_000, 'update_price' );
done_testing;
