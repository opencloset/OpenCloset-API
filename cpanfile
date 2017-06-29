requires 'HTTP::Tiny';
requires 'Try::Tiny';

# cpan.theopencloset.net
requires 'OpenCloset::Common';
requires 'OpenCloset::DB::Plugin::Order::Sale';
requires 'OpenCloset::Schema';

on 'test' => sub {
    requires 'DateTime';
    requires 'Test::More';

    # cpan.theopencloset.net
    requires 'OpenCloset::Calculator::LateFee';
};
