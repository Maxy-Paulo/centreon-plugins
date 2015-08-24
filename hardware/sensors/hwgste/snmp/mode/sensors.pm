#
# Copyright 2015 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


package hardware::sensors::hwgste::snmp::mode::sensors;

use base qw(centreon::plugins::mode);

use strict;
use warnings;
use centreon::plugins::values;

my $thresholds = {
    sensor => [
        ['invalid', 'UNKNOWN'],
        ['normal', 'OK'],
        ['outOfRangeLo', 'WARNING'],
        ['outOfRangeHi', 'WARNING'],
        ['alarmLo', 'CRITICAL'],
        ['alarmHi', 'CRITICAL'],
     ],
};

my %map_temp_status = (
    0 => 'invalid',
    1 => 'normal',
    2 => 'outOfRangeLo',
    3 => 'outOfRangeHi',
    4 => 'alarmLo',
    5 => 'alarmHi',
);
my %map_temp_unit = (
    0 => '', # none
    1 => 'C',
    2 => 'F',
    3 => 'K',
    4 => '%',
);

my $mapping = {
    sensName  => { oid => '.1.3.6.1.4.1.21796.4.1.3.1.2' },
    sensState => { oid => '.1.3.6.1.4.1.21796.4.1.3.1.3', map => \%map_temp_status },
    sensTemp  => { oid => '.1.3.6.1.4.1.21796.4.1.3.1.4' },
    sensUnit  => { oid => '.1.3.6.1.4.1.21796.4.1.3.1.7', map => \%map_temp_unit },
};

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;

    $self->{version} = '0.9';
    $options{options}->add_options(arguments =>
                                {
                                "threshold-overload:s@"   => { name => 'threshold_overload' },
                                "warning:s@"              => { name => 'warning' },
                                "critical:s@"             => { name => 'critical' },
                                });
     return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::init(%options);

    $self->{overload_th} = {};
    foreach my $val (@{$self->{option_results}->{threshold_overload}}) {
        next if (!defined($val) || $val eq '');
        my @values = split (/,/, $val);
        if (scalar(@values) < 3) {
            $self->{output}->add_option_msg(short_msg => "Wrong threshold-overload option '" . $val . "'.");
            $self->{output}->option_exit();
        }
        my ($section, $instance, $status, $filter);
        if (scalar(@values) == 3) {
            ($section, $status, $filter) = @_;
            $instance = '.*';
        } else {
             ($section, $instance, $status, $filter) = @_;
        }
        if ($self->{output}->is_litteral_status(status => $status) == 0) {
            $self->{output}->add_option_msg(short_msg => "Wrong threshold-overload status '" . $val . "'.");
            $self->{output}->option_exit();
        }
        $self->{overload_th}->{$section} = [] if (!defined($self->{overload_th}->{$section}));
        push @{$self->{overload_th}->{$section}}, {filter => $filter, status => $status, instance => $instance };
    }
    
    $self->{numeric_threshold} = {};
    foreach my $option (('warning', 'critical')) {
        foreach my $val (@{$self->{option_results}->{$option}}) {
            if ($val !~ /^(.*?),(.*?),(.*)$/) {
                $self->{output}->add_option_msg(short_msg => "Wrong $option option '" . $val . "'.");
                $self->{output}->option_exit();
            }
            my ($section, $regexp, $value) = ($1, $2, $3);
            if ($section !~ /^(sensor)$/) {
                $self->{output}->add_option_msg(short_msg => "Wrong $option option '" . $val . "' (type must be: sensor).");
                $self->{output}->option_exit();
            }
            my $position = 0;
            if (defined($self->{numeric_threshold}->{$section})) {
                $position = scalar(@{$self->{numeric_threshold}->{$section}});
            }
            if (($self->{perfdata}->threshold_validate(label => $option . '-' . $section . '-' . $position, value => $value)) == 0) {
                $self->{output}->add_option_msg(short_msg => "Wrong $option threshold '" . $value . "'.");
                $self->{output}->option_exit();
            }
            $self->{numeric_threshold}->{$section} = [] if (!defined($self->{numeric_threshold}->{$section}));
            push @{$self->{numeric_threshold}->{$section}}, { label => $option . '-' . $section . '-' . $position, threshold => $option, regexp => $regexp };
        }
    }
}

sub run {
    my ($self, %options) = @_;
    $self->{snmp} = $options{snmp};

    $self->{index} = {};
    my $oid_sensEntry = '.1.3.6.1.4.1.21796.4.1.3.1';

    $self->{results} = $self->{snmp}->get_table(oid => $oid_sensEntry, nothing_quit => 1);
    foreach my $oid (keys %{$self->{results}}) {
        next if ($oid !~ /$mapping->{sensState}->{oid}\.(\d+)$/);
        my $instance = $1;
        my $result = $self->{snmp}->map_instance(mapping => $mapping, results => $self->{results}, instance => $instance);

        $self->{output}->output_add(long_msg => sprintf("Sensor '%s' state is '%s' [instance: %s, value: %s]", 
                                    $result->{sensName}, $result->{sensState}, $instance, $result->{sensTemp}));
        my $exit = $self->get_severity(section => 'sensor',
                                       instance => $instance, value => $result->{sensState});
        if (!$self->{output}->is_status(value => $exit, compare => 'ok', litteral => 1)) {
            $self->{output}->output_add(severity => $exit,
                                        short_msg => sprintf("Sensor '%s' state is '%s'", $result->{sensName}, $result->{sensState}));
        } 
        
        if ($result->{sensTemp} =~ /\d+/) {
            $result->{sensTemp} *= 0.1;
            my ($exit2, $warn, $crit, $checked) = $self->get_severity_numeric(section => 'sensor', instance => $instance, value => $result->{sensTemp});
            if (!$self->{output}->is_status(value => $exit2, compare => 'ok', litteral => 1)) {
                $self->{output}->output_add(severity => $exit2,
                                            short_msg => sprintf("Sensor '%s' value is %s %s", $result->{sensName}, $result->{sensTemp}, $result->{sensUnit}));
            }
            $self->{output}->perfdata_add(label => 'sensor_' . $result->{sensName}, unit => $result->{sensUnit},
                                          value => $result->{sensTemp},
                                          warning => $warn,
                                          critical => $crit);
        }
    }
    $self->{output}->output_add(severity => 'OK',
                                short_msg => sprintf("All sensors are ok."));
    $self->{output}->display();
    $self->{output}->exit();
}

sub get_severity_numeric {
    my ($self, %options) = @_;
    my $status = 'OK'; # default
    my $thresholds = { warning => undef, critical => undef };
    my $checked = 0;
    
    if (defined($self->{numeric_threshold}->{$options{section}})) {
        my $exits = [];
        foreach (@{$self->{numeric_threshold}->{$options{section}}}) {
            if ($options{instance} =~ /$_->{regexp}/) {
                push @{$exits}, $self->{perfdata}->threshold_check(value => $options{value}, threshold => [ { label => $_->{label}, exit_litteral => $_->{threshold} } ]);
                $thresholds->{$_->{threshold}} = $self->{perfdata}->get_perfdata_for_output(label => $_->{label});
                $checked = 1;
            }
        }
        $status = $self->{output}->get_most_critical(status => $exits) if (scalar(@{$exits}) > 0);
    }
    
    return ($status, $thresholds->{warning}, $thresholds->{critical}, $checked);
}

sub get_severity {
    my ($self, %options) = @_;
    my $status = 'UNKNOWN'; # default 
    
    if (defined($self->{overload_th}->{$options{section}})) {
        foreach (@{$self->{overload_th}->{$options{section}}}) {            
            if ($options{value} =~ /$_->{filter}/i) {
                $status = $_->{status};
                return $status;
            }
        }
    }
    my $label = defined($options{label}) ? $options{label} : $options{section};
    foreach (@{$thresholds->{$label}}) {
        if ($options{value} =~ /$$_[0]/i) {
            $status = $$_[1];
            return $status;
        }
    }
    
    return $status;
}

1;

__END__

=head1 MODE

Check HWg-STE sensors.

=over 8

=item B<--threshold-overload>

Set to overload default threshold values (syntax: section,[instance,]status,regexp)
It used before default thresholds (order stays).
Example: --threshold-overload='sensor,CRITICAL,^(?!(normal)$)'

=item B<--warning>

Set warning threshold for temperatures (syntax: type,instance,threshold)
Example: --warning='sensor,.*,30'

=item B<--critical>

Set critical threshold for temperatures (syntax: type,instance,threshold)
Example: --critical='sensor,.*,40'

=back

=cut
