package PVE::Storage::Custom::HseVmbPlugin;

=head1 NAME

HseVmb Storage Plugin - Proxmox VE Storage Plugin for VM Backup

=head1 DESCRIPTION

This plugin integrates Proxmox VE storage with VM Backup,
by Hornetsecurity.

=head1 AUTHOR

Hornetsecurity Ltd.

=cut

use strict;
use warnings FATAL => 'all';

use base qw(PVE::Storage::Plugin);
use PVE::BackupProvider::Plugin::HseVmbBackupProvider;
use File::Path qw(make_path);
use Data::Dumper;

sub api {
    # @_ = ['PVE::Storage::Custom::HseVmbPlugin']

        # PVE 8.4 | APIVER 11 | e2dc01ac9f06 | new_backup_provider: sensitive_properties                | Used
        # PVE 9   | APIVER 12 | 280bb6be777a | qemu_blockdev_options: rename_snapshot, get_formats      | Not used
        # PVE 9   | APIVER 13 | 8818ff0d1d70 | add $hints to activate_volume(), map_volume() (unused)   | Not used
        # PVE 9   | APIVER 13 | 0b1331ccda6d | add on_update_hook_full()                                | Not used

        # For reference: https://github.com/proxmox/pve-storage/commits/master/

        my $supported_minver = 11;
        my $supported_maxver = 13;

        my $apiver = PVE::Storage::APIVER;

        # Check if the API version is within our supported range
        if ($apiver >= $supported_minver && $apiver <= $supported_maxver) {
            return $apiver;
        }
        else {
            return $supported_maxver;
        }
}

sub type {
    # @_ = ['PVE::Storage::Custom::HseVmbPlugin']
    return 'hse-vmb';
}

sub has_isolated_properties {
    # @_ = ['PVE::Storage::Custom::HseVmbPlugin']
    return 1;
}

sub options {
    # @_ = ['PVE::Storage::Custom::HseVmbPlugin']

    # options can be:
    #   => { fixed => 1 }: can only be set on creation
    #   => { optional => 1 }: not required!
    #   => {}: required but not fixed
    
    return {
        # mandatory properties
        path => { fixed => 1 },
        content => { fixed => 1 },
    };
}

sub plugindata {
    # @_ = ['PVE::Storage::Custom::HseVmbPlugin']
    
    return {
        # allowed content types
        content => [
            { backup => 1 },    # storage: stores backups, content type "backup" is required by vzdump
            { backup => 1 }     # backup provider: stores backups only 
        ],
        features => { 'backup-provider' => 1 },
    };
}

# sub properties {
#     # @_ = ['PVE::Storage::Custom::HseVmbPlugin']
#     return {
#     };
# }

sub check_config {
    # pvesm add:
    # [
    #     'PVE::Storage::Custom::HseVmbPlugin',
    #     'hse-vmb-store',
    #     {},
    #     1,
    #     1
    # ];
    # other:
    # [
    #     'PVE::Storage::Custom::HseVmbPlugin',
    #     'hse-vmb-store',
    #     {
    #         'path' => '/var/lib/hse-vmb/pve-storage/hse-vmb-store',
    #         'type' => 'hse-vmb'
    #     },
    #     1,
    #     1
    # ];

    my ($class, $storeid, $scfg, $create, $skipSchemaCheck) = @_;

    if (defined $scfg->{type} && $scfg->{type} ne $class->type()) {
        die "unexpected type '$scfg->{type}'";
    }
    
    if ($create // 0) {
        # check whether a value has been set for all required properties

        # if no path is specified, default as follows
        if (! defined $scfg->{path}) {
            $scfg->{path} = "/var/lib/" . $class->type() . "/pve-storage/$storeid";
        }

        # if no content is specified, default as follows
        if (! defined $scfg->{content}) {
            $scfg->{content} = "backup";
        }
    }
    
    return $class->SUPER::check_config($storeid, $scfg, $create, $skipSchemaCheck);
}


sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # ensure that the path is created
    my $path = $scfg->{path};
    $class->config_aware_base_mkdir($scfg, $path);
    
    $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub new_backup_provider {
    # @_ = [
    #     'PVE::Storage::Custom::HseVmbPlugin',
    #     {
    #         'type' => 'hse-vmb',
    #         'path' => '/var/lib/hse-vmb/pve-storage/hse-vmb-store',
    #         'content' => {
    #             'backup' => 1
    #         }
    #     },
    #     'hse-vmb-store',
    #     sub { "DUMMY" }
    # ];
    
    # print "new_backup_provider: " . Dumper(\@_);
    return PVE::BackupProvider::Plugin::HseVmbBackupProvider->new(@_);
}

1;