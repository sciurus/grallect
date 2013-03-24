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
      :cpu => { :count => 2, :warning => 80, :critical => 95 },
      :memory => { :warning => 80, :critical => 95 },
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
      code = 3
      output = 'UNKNOWN: No data was found'
    end

    results.each { |r| output = output + "#{r[:name]} averaged #{r[:value]}%. " }

    puts output
    exit code
  end

  def check_cpu
    results = []
    code = nil

    # Checking each cpu individually
    range = (0..@config[:cpu][:count]-1)
    range.each do |i|
      data = self.get_data("sumSeries(#{@host_path}.cpu-#{i}.cpu-{user,system})")
      if data.empty?
        @logger.warn "No data found"
      else
        value = data.first['datapoints'].last.first
        results.push({:name => "CPU #{i}", :value => value})
        if value >= @config[:cpu][:warning] and value < @config[:cpu][:critical]
          code = 1
        elsif value >= @config[:cpu][:critical]
          code = 2
        else
          code = 0
        end
      end
    end

    output_status(code, results)
  end

  def check_memory
    results = []
    code = nil

    data = self.get_data("asPercent(#{@host_path}.memory.memory-{used,free})")

    if data.empty?
      @logger.warn "No data found"
    else
      value = data.first['datapoints'].last.first
      results.push({:name => "Memory", :value => value})
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
command = 'memory'
host = 'example.com'

g = Grallect.new(host)

case command
when 'cpu'
  g.check_cpu
when 'memory'
  g.check_memory
else
  puts 'What kind of command is that?'
end
