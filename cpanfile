requires 'DateTime';
requires 'DateTime::Format::ISO8601';
requires 'HTTP::Tiny';
requires 'Mojolicious';    # Mojo::Loader, Mojo::Template
requires 'Try::Tiny';

# cpan.theopencloset.net
requires 'OpenCloset::Common';
requires 'OpenCloset::DB::Plugin::Order::Sale';
requires 'OpenCloset::Events::EmploymentWing', 'v0.1.0';
requires 'OpenCloset::Schema', '0.056';

on 'test' => sub {
    requires 'DateTime';
    requires 'Test::More';

    # cpan.theopencloset.net
    requires 'OpenCloset::Calculator::LateFee';
};
