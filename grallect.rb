#!/usr/bin/env ruby


require 'json'
require 'logger'
require 'open-uri'
require 'optparse'
require 'uri'
require 'pp'

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
    rescue SocketError => e
      @logger.fatal e.message
      exit 1
    end

    begin
      data = JSON.parse(response)
    rescue ParserError => e
      @logger.fatal e.message
      exit 1
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

  def check_interface
    results = []
    code = nil

    # fetch both tx and rx at once
    # checking them seperatly instead of combining
    data = self.get_data("#{@host_path}.interface-*.if_octets.*")

    if data.empty?
      code = 3
    else
      data.each do |d|
        interface = /interface-(.*?)\./.match(d['target'])[1]
        direction = /if_octets\.(.*),/.match(d['target'])[1]
        # convert bytes to megabits
        value = d['datapoints'].last.first / 131072
        code = update_code(code, value, @config['interface']['warning'], @config['interface']['critical'])
        results.push({'label' => "Interface #{interface} #{direction} transferred", 'value' => value})
      end
    end

    output_status(code, results)
  end

  def check_memory
    results = []
    code = nil

    # this fetches memory used as percentage of total memory
    # and memory free as percetage of total memory
    # we only check the former
    data = self.get_data("asPercent(#{@host_path}.memory.memory-{used,free})")

    if data.empty?
      code = 3
    else
      value = data.first['datapoints'].last.first
      code = update_code(code, value, @config['memory']['warning'], @config['memory']['critical'])
      results.push({'label' => 'Memory usage percentage', 'value' => value})
    end

    output_status(code, results)
  end
end




VERSION = '20130401'

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
  exit 1
end

host = ARGV[0]
metric = ARGV[1]

begin
  config = JSON.load( File.read( config_path ) )
rescue => e
  $stderr.puts e.message
  exit 1
end

g = Grallect.new(host, verbose, config)

if g.respond_to?("check_#{metric}")
  g.send("check_#{metric}")
else
  $stderr.puts "I do not know how to check #{metric}"
end
