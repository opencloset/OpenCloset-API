use strict;
use warnings;
use Test::More;

BEGIN { use_ok('OpenCloset::API'); }
BEGIN { use_ok('OpenCloset::API::Order'); }
BEGIN { use_ok('OpenCloset::API::SMS'); }
BEGIN { use_ok('OpenCloset::API::OrderDetail'); }

done_testing;
