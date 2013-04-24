#!/usr/bin/env ruby


require 'json'
require 'logger'
require 'open-uri'
require 'optparse'
require 'uri'

class Grallect

  def initialize(host, verbose, config)
    @config = config

    @logger = Logger.new(STDERR)
    @logger.level = verbose ? Logger::DEBUG : Logger::ERROR

    escaped_host = host.gsub('.', @config['collectd']['escape_character'])
    @host_path = "#{@config['collectd']['prefix']}#{escaped_host}#{@config['collectd']['postfix']}"
  end

  def get_data(graphite_expression)
    # number of data points to average together
    samples = @config['window'] / @config['collectd']['interval']

    url = URI.escape("#{@config['graphite']['url']}/render/?format=json&target=movingAverage(#{graphite_expression},#{samples})&from=-#{@config['window']}seconds")
    @logger.debug URI.unescape(url)

    begin
      response = open(url).read
      @logger.debug response
    rescue => e
      @logger.fatal e.message
      puts "UNKNOWN: Internal error"
      exit 3
    end

    begin
      data = JSON.parse(response)
    rescue => e
      @logger.fatal e.message
      puts "UNKNOWN: Internal error"
      exit 3
    end

    return data
  end

  def output_status(code, results)
    case code
    when 0
      output = 'OK: '
    when 1
      output = 'WARNING: '
    when 2
      output = 'CRITICAL: '
    else
      output = 'UNKNOWN: No data was found'
    end

    results.each { |r| output = output + "#{r['label']} was #{r['value']}. " }

    puts output
    exit code
  end

  def update_code(code, value, warning, critical)
    case code
    when 3
      return 3
    when 2
      return 2
    when 1
      if value >= critical
        return 2
      else
        return 1
      end
    else
      if value >= warning and value <= critical
        return 1
      elsif value >= critical
        return 2
      else
        return 0
      end
    end
  end

  def perform_single_check(check_name, target, percentage=false)
    results = []
    code = nil

    graphite_expression = "#{@host_path}.#{target}"
    graphite_expression = "asPercent(#{graphite_expression})" if percentage

    # example target with percentage is memory.memory-{used,free}
    data = self.get_data(graphite_expression)

    if data.empty?
      code = 3
    else
      value = data.first['datapoints'].last.first
      code = update_code(code, value, @config[check_name]['warning'], @config[check_name]['critical'])
      results.push({'label' => "#{check_name} usage percentage", 'value' => value})
    end

    output_status(code, results)
  end

  def check_cpu
    results = []
    code = nil

    # fetching user and system seperately makes handling the results easier
    user_data = self.get_data("#{@host_path}.cpu-*.cpu-user")
    system_data = self.get_data("#{@host_path}.cpu-*.cpu-system")

    # extract usage for each cpu
    user_values = user_data.map { |d| d['datapoints'].last.first }
    system_values = system_data.map { |d| d['datapoints'].last.first }

    # extract cpu identifiers
    labels = user_data.map { |d| /cpu-(.*?)\./.match(d['target'])[1] }

    # add user and system data together for the check
    values = [user_values, system_values].transpose.map { |a| a.reduce(:+) }

    # combine labels and values
    data = Hash[labels.zip(values)]

    if data.empty?
      code = 3
    else
      data.each_key do |k|
        code = update_code(code, data[k], @config['cpu']['warning'], @config['cpu']['critical'])
        results.push({'label' => "CPU #{k} usage percentage", 'value' => data[k]})
      end
    end

    output_status(code, results)
  end

  def check_disk
    results = []
    code = nil

    # fetching data in similar style to cpu

    # have graphite turn raw iops into percentage for me
    read_data = self.get_data("asPercent(#{@host_path}.disk-sd*.disk_ops.read,#{@config['disk']['iops']})")
    write_data = self.get_data("asPercent(#{@host_path}.disk-sd*.disk_ops.write,#{@config['disk']['iops']})")

    read_values = read_data.map { |d| d['datapoints'].last.first }
    write_values = write_data.map { |d| d['datapoints'].last.first }

    labels = read_data.map { |d| /disk-(.*?)\./.match(d['target'])[1] }
    values = [read_values, write_values].transpose.map { |a| a.reduce(:+) }
    data = Hash[labels.zip(values)]

    if data.empty?
      code = 3
    else
      data.each_key do |k|
        code = update_code(code, data[k], @config['disk']['warning'], @config['disk']['critical'])
        results.push( {'label' => "Disk #{k} activity percentage", 'value' => data[k]} )
      end
    end

    output_status(code, results)
  end

  def check_df
    results = []
    code = nil

    # having to fetch these seperately and calculate percentage myself
    # because "asPercent(#{@host_path}.df-*.df_complex-{used,free})"
    # would calculate percentage across all filesystems
    used_data = self.get_data("#{@host_path}.df-*.df_complex-used")
    free_data = self.get_data("#{@host_path}.df-*.df_complex-free")

    used_values = used_data.map { |d| d['datapoints'].last.first }
    free_values = free_data.map { |d| d['datapoints'].last.first }

    labels = used_data.map { |d| /df-(.*?)\./.match(d['target'])[1] }
    # convert to percentage
    values = [used_values, free_values].transpose.map { |a| a.first / (a.first + a.last) * 100 }
    data = Hash[labels.zip(values)]

    if data.empty?
      code = 3
    else
      data.each_key do |k|
        code = update_code(code, data[k], @config['df']['warning'], @config['df']['critical'])
        results.push( {'label' => "Disk #{k} space used percentage", 'value' => data[k]} )
      end
    end

    output_status(code, results)
  end

  def check_interface
    results = []
    code = nil

    # could have graphite do this too via scale()
    bytes_per_second = @config['interface']['mbps'] * 131072

    # fetch both tx and rx at once
    # have graphite transform octets transferred into percentage of interface transfer rate for me
    data = self.get_data("asPercent(#{@host_path}.interface-*.if_octets.*,#{bytes_per_second})")

    if data.empty?
      code = 3
    else
      data.each do |d|
        interface = /interface-(.*?)\./.match(d['target'])[1]
        direction = /if_octets\.(.*?),/.match(d['target'])[1]
        value = d['datapoints'].last.first
        code = update_code(code, value, @config['interface']['warning'], @config['interface']['critical'])
        results.push({'label' => "Interface #{interface} #{direction} usage percentage", 'value' => value})
      end
    end

    output_status(code, results)
  end

  def check_memory
    perform_single_check('memory', 'memory.memory-{used,free}', true)
  end

  def check_swap
    perform_single_check('swap', 'swap.swap-{used,free}', true)
  end

  def check_load
    perform_single_check('load', 'load.load.shortterm')
  end

end




VERSION = '20130424'

verbose = false
config_path = File.expand_path('../grallect.json', __FILE__)

OptionParser.new do |opts|
  opts.banner = 'Usage: grallect [options] host metric'

  opts.on('-c', '--config FILE', 'Path to configuration file') do |c|
    config_path = c
  end

  opts.on('-v', '--[no-]verbose', 'Run verbosely') do |v|
    verbose = v
  end

   opts.on( '-h', '--help', 'Display this screen' ) do
     puts opts
     exit
   end

   opts.on_tail('--version', 'Show version') do
     puts VERSION
     exit
    end
end.parse!

if ARGV.length != 2
  $stderr.puts 'USAGE: grallect host metric'
  puts "UNKNOWN: Internal error"
  exit 3
end

host = ARGV[0]
metric = ARGV[1]

begin
  config = JSON.load( File.read( config_path ) )
rescue => e
  $stderr.puts e.message
  puts "UNKNOWN: Internal error"
  exit 3
end

g = Grallect.new(host, verbose, config)

if g.respond_to?("check_#{metric}")
  g.send("check_#{metric}")
else
  $stderr.puts "I do not know how to check #{metric}"
  puts "UNKNOWN: Internal error"
  exit 3
end
