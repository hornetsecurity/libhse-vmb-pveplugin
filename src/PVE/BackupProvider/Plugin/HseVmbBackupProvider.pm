package PVE::BackupProvider::Plugin::HseVmbBackupProvider;

=head1 NAME

HseVmb Backup Provider Plugin - Proxmox VE Backup Provider Plugin for VM Backup

=head1 DESCRIPTION

This plugin implements the Proxmox VE Backup Provider interface to
enable coordinated VM backups using "VM Backup", a product
by Hornetsecurity.

=head1 AUTHOR

Hornetsecurity Ltd.

=cut

use strict;
use warnings FATAL => 'all';

use base qw(PVE::BackupProvider::Plugin::Base);

use Data::Dumper;
use POSIX qw(strftime);
use IO::Socket::UNIX;
use JSON;

# constants
use constant PLUGIN_PACKAGE_VERSION => "2.0.2.0";
use constant PLUGIN_VERSION => "2.0.2.0";

# constructor
sub new {
    my ($class, $storage_plugin, $scfg, $storeid, $log_function) = @_;

    my $self = bless {
        storage_plugin => $storage_plugin,
        scfg => $scfg,
        storeid => $storeid,
        log_function => $log_function,
    }, $class;
    
    return $self;
}

### Logging

sub log_info {
    my ($self, $message) = @_;
    $self->{log_function}("info", $message);
}

sub log_warn {
    my ($self, $message) = @_;
    $self->{log_function}("warn", $message);
}

sub log_err {
    my ($self, $message) = @_;
    $self->{log_function}("err", $message);
}

### Jobs

sub job_init {
    my ($self, $start_time) = @_;

    # $self->log_info("Job started at " . strftime("%FT%T%z %Z", localtime($start_time)) . "  ($start_time)");
    $self->{job_start_time} = $start_time;
}

sub job_cleanup {
    # my ($self) = @_;
}

### IPC (interprocess communication with VMB)

sub open_ipc {
    my ($self) = @_;

    my $sock_file = "/run/" . $self->{storage_plugin}->type() ."/backup-" . $self->{vmid} . "/ipc.sock";
    $self->log_info("Connecting to VM Backup");

    # Connect to the SSH session’s listener
    my $sock = IO::Socket::UNIX->new(
        Peer => $sock_file,
        Type => SOCK_STREAM(),
    ) or die "Cannot connect to VM Backup: $!";

    $self->log_info("Connected to VM Backup");
    $self->{sock} = $sock;
}

sub close_ipc {
    my ($self) = @_;

    if (exists $self->{sock}) {
        $self->log_info("Disconnecting from VM Backup");

        close $self->{sock}
            or log_warn("Failed to disconnect from VM Backup: $!");

        $self->log_info("Disconnected from VM Backup");
        delete $self->{sock};
    }
}

sub send_ipc {
    my ($self, $msg_id, $payload) = @_;
    
    if (!defined($msg_id) || $msg_id eq '') {
        die "Invalid message ID: " . ($msg_id // "<<undef>>");
    }

    # Send a JSON-encoded message (for example)
    my $msg = {
        msg_id => $msg_id,
        payload => $payload,
        flow => "request",
    };
    my $sock = $self->{sock};
    
    my $json_request = encode_json($msg);
    print $sock $json_request . "\n";

    # Read a response from your app (if any)
    my $json_reply = <$sock>;
    
    if (!defined($json_reply)) {
        $self->close_ipc();
        die "Lost connection to VM Backup";
    }
    
    my $reply = decode_json($json_reply);
    if (!exists($reply->{msg_id}) || !defined($reply->{msg_id}) || $reply->{msg_id} ne $msg_id) {
        die "Unexpected message ID: " . ($msg_id // "<<undef>>") . " for $msg_id";
    }
    
    if (!exists($reply->{flow}) || !defined($reply->{flow}) || $reply->{flow} ne "reply") {
        die "Unexpected flow for message $msg_id: " . ($reply->{flow} // "<<undefined>>");
    }
    
    return $reply;
}

### Backups

sub provider_name {
    # my ($self) = @_;
    return "HseVmbBackup";
}

sub backup_init {
    my ($self, $vmid, $vmtype, $start_time) = @_;

    if ($vmtype ne "qemu") {
        die "Guest type $vmtype is not supported by the backup provider";
    }

    $self->{vmid} = $vmid;
    $self->{backup_start_time} = $start_time;

    $self->log_info("Backup started at " . strftime("%FT%T%z %Z", localtime($start_time)) . "  ($start_time)");

    my $archive_name = "hse-vmb-vm-${vmid}-" . strftime("%Y%m%dT%H%M%SZ", gmtime($start_time));
    $self->{archive_name} = $archive_name;
    
    $self->open_ipc();

    my $reply = $self->send_ipc("backup_init", {
        vm_id => $vmid,
        storage => $self->{storeid},
        storage_path => $self->{scfg}->{path},
        versions => {
            'package' => PLUGIN_PACKAGE_VERSION,
            backup_provider_plugin => PLUGIN_VERSION,
        }
    });
    
    if (!exists($reply->{payload}) || !defined($reply->{payload})
        || !exists($reply->{payload}->{vmb_version}) || !defined($reply->{payload}->{vmb_version})) {
        die "Reply not supported"
    }
    
    $self->log_info("VM Backup $reply->{payload}->{vmb_version}");

    return {
        'archive-name' => $archive_name
    };
}

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;

    if ($vmid != $self->{vmid} || $vmtype ne "qemu") {
        die "unexpected vm $vmid or vm type $vmtype";
    }
    
    my $reply = $self->send_ipc("backup_get_mechanism", {
    });

    return $reply->{payload}->{mechanism};
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $volumes) = @_;
    
    if ($vmid != $self->{vmid}) {
        die "unexpected vm $vmid";
    }
    
    my $reply = $self->send_ipc("backup_vm_query_incremental", {
        volumes => $volumes,
    });

    return $reply->{payload}->{bitmap_actions};
}

sub backup_vm {
    my ($self, $vmid, $vmconfig, $volumes, $info) = @_;
    # $info can specify the 'bandwidth-limit' and 'firewall-config'

    if ($vmid != $self->{vmid}) {
        die "unexpected vm $vmid";
    }
    
    my $reply = $self->send_ipc("backup_vm", {
        vm_config => $vmconfig,
        backup_volumes => $volumes,
    });
    
    die "VM Backup backup was not successful"
        if !exists($reply->{payload})
            || !exists($reply->{payload}->{backup_success})
            || ($reply->{payload}->{backup_success} // 0) == 0;
}

sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;

    $success = 0
        if !defined $success;
    
    if ($success) {
        if ($vmid != $self->{vmid}) {
            die "unexpected vm $vmid";
        }

        if ($vmtype ne "qemu") {
            die "Guest type $vmtype is not supported by the backup provider";
        }

        if (!exists $self->{sock}) {
            die "VM Backup is disconnected";
        }
    }

    my $archive_size = 0;
    
    if (exists $self->{sock}) {
        my $reply = $self->send_ipc("backup_cleanup", {
            backup_success => $success,
            info => $info,
        });
        
        if (exists $reply->{payload} && exists($reply->{payload}->{backup_size_in_bytes})) {
            $archive_size = $reply->{payload}->{backup_size_in_bytes} // 0;
        }
    }

    my $result;
    if ($success) {
        # for successful backups we must return statistics ('archive-size')
        $result = {
            stats => {
                'archive-size' => $archive_size,
            },
        };
    }

    $self->close_ipc();
    
    return $result;
}

sub backup_handle_log_file {
    # my ($self, $vmid, $log_path) = @_;
}

1;