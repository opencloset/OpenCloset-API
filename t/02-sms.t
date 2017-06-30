use utf8;
use strict;
use warnings;

use open ':std', ':encoding(utf8)';
use Test::More;

use OpenCloset::Schema;
use OpenCloset::API::SMS;

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

my $api = OpenCloset::API::SMS->new( schema => $schema, notify => 0 );
ok( $api, 'OpenCloset::API::SMS->new' );
my $success = $api->send( to => '01012345678', msg => 'hi' );
ok( $success, 'send' );

$success = $api->send( to => '01012345678', msg => '한글' );
ok( $success, 'send 한글 msg' );
done_testing;
