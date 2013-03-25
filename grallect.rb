#!/usr/bin/env ruby


require 'json'
require 'logger'
require 'open-uri'
require 'pp'
require 'uri'

class Grallect

  def initialize(host)
    # this should be generated by merging together defaults and a configuration file
    @config = { 
      :graphite => { :url => 'http://localhost' },
      :collectd => { :prefix => nil, :postfix => '.collectd', :escape_character => '_', :interval => 10 },
      :cpu => { :warning => 80, :critical => 95 },
      :memory => { :warning => 80, :critical => 95 },
      :interface => { :speed => 1000, :warning => 80, :critical => 95 },
      :window => 60,
      :verbose => true,
    }

    escaped_host = host.gsub!('.', @config[:collectd][:escape_character])
    @host_path = "#{@config[:collectd][:prefix]}#{escaped_host}#{@config[:collectd][:postfix]}"

    @logger = Logger.new(STDERR)
    @logger.level = @config[:verbose] ? Logger::DEBUG : Logger::ERROR
  end

  def get_data(graphite_function)
    # number of data points to average together
    samples = @config[:window] / @config[:collectd][:interval]

    url = URI.escape("#{@config[:graphite][:url]}/render/?format=json&target=movingAverage(#{graphite_function},#{samples})&from=-#{@config[:window]}seconds")
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

    results.each { |r| output = output + "#{r[:label]} was #{r[:value]}. " }

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

    # fetching the data seeprately makes parsing results easier
    user_data = self.get_data("#{@host_path}.cpu-*.cpu-user")
    system_data = self.get_data("#{@host_path}.cpu-*.cpu-system")

    user_values = user_data.map { |d| d['datapoints'].last.first }
    system_values = system_data.map { |d| d['datapoints'].last.first }

    # array with sum of each pair of user and system data
    values = [user_values, system_values].transpose.map { |a| a.reduce(:+) }

    if values.empty?
      @logger.warn "No data found"
      code = 3
    else
      values.each_with_index do |value, i|
        results.push({:label => "CPU #{i} usage percentage", :value => value})
      end
      highest = values.sort.last
      if highest >= @config[:cpu][:warning] and highest < @config[:cpu][:critical]
        code = 1
      elsif highest >= @config[:cpu][:critical]
        code = 2
      else
        code = 0
      end
    end

    output_status(code, results)
  end

  def check_interface
    results = []
    code = nil

    data = self.get_data("#{@host_path}.interface-*.if_octets.*")

    if data.empty?
      @logger.warn "No data found"
      code = 3
    else
      data.each do |d|
        interface = /interface-(.*?)\./.match(d['target'])[1]
        direction = /if_octets\.(.*),/.match(d['target'])[1]
        # convert bytes to megabits
        value = d['datapoints'].last.first / 131072
        code = update_code(code, value, @config[:interface][:warning], @config[:interface][:critical])
        results.push({:label => "Interface #{interface} #{direction} transferred", :value => value})
      end
    end

    output_status(code, results)
  end

  def check_memory
    results = []

    data = self.get_data("asPercent(#{@host_path}.memory.memory-{used,free})")

    if data.empty?
      @logger.warn "No data found"
      code = 3
    else
      value = data.first['datapoints'].last.first
      results.push({:label => "Memory usage percentage", :value => value})
      if value >= @config[:memory][:warning] and value < @config[:memory][:critical]
        code = 1
      elsif value >= @config[:memory][:critical]
        code = 2
      else
        code = 0
      end
    end

    output_status(code, results)
  end

end

# this should be generated by command line arguments
command = ARGV[0]
host = 'example.com'

g = Grallect.new(host)

case command
when 'cpu'
  g.check_cpu
when 'memory'
  g.check_memory
when 'interface'
  g.check_interface
else
  puts 'What kind of command is that?'
end
