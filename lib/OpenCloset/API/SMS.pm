package OpenCloset::API::SMS;

use utf8;
use strict;
use warnings;

=encoding utf8

=head1 NAME

OpenCloset::API::SMS - SMS

=head1 SYNOPSIS

    my $api = OpenCloset::API::SMS(schema => $schema);
    my $success = $api->send(from => '0269291029', to => '01012345678', msg => 'oops');

=cut

=head1 METHODS

=head2 new

    my $api = OpenCloset::API::SMS->new(schema => $schema);

=over

=item *

schema - S<OpenCloset::Schema>

=back

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = { schema => $args{schema} };
    bless $self, $class;
    return $self;
}

=head2 send( from => $from?, to => $to, msg => $msg )

    my $success = $api->send(from => '0269291029', to => '01012345678', msg => 'oops');

발신번호는 등록된 번호만 가능합니다.

default is C<0269291029>

=cut

our $SMS_FROM = '0269291029';

## TODO: 발신 가능한 번호 목록

sub send {
    my ( $self, %args ) = @_;
    return unless $args{to};
    return unless $args{msg};

    my $from = $args{from} || $SMS_FROM;
    my $to = $args{to};

    $to =~ s/[^0-9]//g;
    $from =~ s/[^0-9]//g;

    my $sms = $self->{schema}->resultset('SMS')->create(
        {
            from => $from,
            to   => $to,
            text => $args{msg}
        }
    );

    unless ($sms) {
        warn "Failed to create a new SMS: $args{msg}";
        return;
    }

    return $sms;
}

=head1 AUTHOR

Hyungsuk Hong

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2017 열린옷장

=cut

1;
