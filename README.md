# Usage

grallect [options] host metric
    -c, --config FILE                Path to configuration file
    -v, --[no-]verbose               Run verbosely
    -h, --help                       Display this screen
        --version                    Show version

# Supported metrics

* cpu
* disk
* df
* interface
* memory
* swap
* load
* java_heap
* java_nonheap

The java metrics assume you are using jolokia and the curl_json plugin.

# Configuration options

A sample config file is included as grallect.json

The options in it need documenting.
