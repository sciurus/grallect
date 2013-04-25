# Usage

    grallect [options] host metric
        -c, --config FILE                Path to configuration file
        -v, --[no-]verbose               Run verbosely
        -h, --help                       Display this screen
            --version                    Show version

By default, the configuration file is looked for in the same directory as grallect. To use an alternate path, specify it with `-c` option.

Use `-v` to see the request made to graphite and the response.

# Supported metrics

* cpu - cpu  usage
* df - disk space usage
* disk - disk i/o activity
* interface - network network usage
* load - short term load average
* memory - memory usage
* swap - swap usage
* java\_heap - JVM heap memory usage
* java\_nonheap - JVM nonheap memory usage

# Configuration options

A sample config file is included as grallect.json

* The *warning* and *critcal* keys determine the warning and critical thresholds for a metric. All of these are a percentage of utilization, except for load. For load, they are the short-term load value.
* *url* is the URL of your graphite server.
* *remove_from_hostname* is useful if the hostname in your nagios installation has a prefix or postfix that is not a part of the hostname stored in graphite. If you don't need this behavior, just leave it null.
* The *prefix*, *postfix*, and *escape_character* options should match your collectd [write_graphite configuration](http://collectd.org/documentation/manpages/collectd.conf.5.shtml#plugin_write_graphite). The *interval* should match the interval from collectd's [global options](http://collectd.org/documentation/manpages/collectd.conf.5.shtml#global_options).
* *window* is number of seconds to average values over when checking threshholds.
* *iops*  is the number of i/o operations per second your disks can perform. Used to calculate a percentage value for how busy your disks are.
* *mbps* is the number of megabits per second your network interfaces can transfer. Used to calculate a percentage value for how busy your interfaces are.
