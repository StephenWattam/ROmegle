# Ruby Omegle interface.  Written by Stephen Wattam, http://www.stephenwattam.com
# Based on the ruby-omegle gem, with major updates.
# Thanks to the original author, Mikhail Slyusarev
#
# Many thanks to the various protocol descriptions people did that helped with this.
#

# TODO:
# 1. Support for recaptcha, when challenged.
#



#http://code.google.com/p/omegle-api/wiki/Home#IDs_and_events
#https://github.com/nikkiii/omegle-api-java/blob/master/src/org/nikki/omegle/Omegle.java
#//Omegle events
#	waiting, connected, gotMessage, strangerDisconnected, typing, stoppedTyping, recaptchaRequired, recaptchaRejected, count, 
#
#	//Spy mode events
#	spyMessage, spyTyping, spyStoppedTyping, spyDisconnected, question, error, commonLikes, 
#
#	//Misc events
#	antinudeBanned,
## 
#http://code.google.com/p/saf-omegle/wiki/Events

require 'uri'
require 'net/http'
require 'json'
require 'thread'

# Class for handling connections with omegle.
class Omegle

  # Passed to omegle in every call
  STATIC_HEADERS = {"referer" => "http://omegle.com"}

  # Default options
  DEFAULT_OPTIONS = {:host     => 'omegle.com',
                     :question => nil,
                     :topics   => nil,
                     :answer   => false,
                     :headers  => STATIC_HEADERS}

  # The ID of this session
  attr_accessor :id

  # Establish connection here to the omegle host
  # (ie. omegle.com or cardassia.omegle.com).
  def initialize(options = {})
    # mutex for multiple access to send/events
    @mx = Mutex.new
    @options = DEFAULT_OPTIONS

    # Load and validate config options
    integrate_configs(options)

    # FIFO for events
    @events = []
  end

  # Static method that will handle connecting/disconnecting to
  # a person on omegle. Same options as constructor.
  def self.start(options = {})
    s = Omegle.new(options)
    s.start
    yield s
    s.disconnect
  end

  # Make a GET request to <omegle url>/start to get an id.
  def start(options = {})
    integrate_configs(options)
    
    # Connect to start a session in one of three modes
    if(@options[:question]) then
      resp = req("start?rcs=1&firstevents=1&spid=&randid=#{get_randID}&cansavequestion=1&ask=#{URI::encode(@options[:question])}", :get)
    elsif(@options[:answer]) then
      resp = req("start?firstevents=1&wantsspy=1", :get)   #previously ended at 6
    else
      topicstring = ""
      topicstring = "&topics=#{ URI::encode(@options[:topics].to_s) }" if @options[:topics].is_a?(Array)
      resp = req("start?firstevents=1#{topicstring}", :get)   #previously ended at 6
    end
    
    # Was the response JSON?
    if resp =~ /^"[\w]+:\w+"$/ then
      # not json, simply strip quotes
      @id = resp[1..-2]
    else
      #json
      # parse, find ID, add first events
      resp = JSON.parse(resp)
      raise "No ID in connection response!" if not resp["clientID"]
      @id = resp["clientID"]

      # Add events if we requested it.
      add_events(resp["events"]) if resp["events"]
    end
  end

  # POST to <omegle url>/events to get events from Stranger.
  def poll_events
    ret = req('events', "id=#{@id}")
    parse_response(ret)
  end

  # Send a message to the Stranger with id = @id.
  def send(msg)
    t = Time.now
    ret = req('send', "id=#{@id}&msg=#{URI::encode(msg)}")
    parse_response(ret)
  end

  # Let them know you're typing.
  def typing
    ret = req('typing', "id=#{@id}")
    parse_response(ret)
  end

  # Disconnect from Stranger
  def disconnect
    ret = req('disconnect', "id=#{@id}")
    @id = nil if ret != nil
    parse_response(ret)
  end

  # Is this object in a session?
  def connected?
    @id != nil
  end

  # Is spy mode on?
  def spy_mode?
    @options[:question] != nil
  end

  # Does this session have any topics associated?
  def topics
    @options[:topics]
  end

  # Pass a code block to deal with each events as they come.
  def listen
    # Get any events since last call
    poll_events

    # repeatedly yield any incoming events,
    # and keep polling. 
    #
    # This drops out when no events are
    # available, and automatically polls for more
    while (e = @events.pop) != nil
      yield e
      poll_events if @events.length == 0
    end
  end

  private

  # Merges configs with the 'global config'
  # can only work when not connected
  def integrate_configs(options = {})
    @mx.synchronize{
      raise "Cannot alter session settings whilse connected."     if @id != nil
      raise "Topics cannot be specified along with a question."   if options[:question] and options[:topics]
      raise "Topics cannot be specified along with answer mode"   if options[:answer]   and options[:topics]
      raise "Answer mode cannot be enabled along with a question" if options[:answer]   and options[:question]
    }
    @options.merge!(options)
  end


  # Make a request to omegle.  Synchronous.
  # set args = :get to make a get request, else it's post.
  #
  # Returns the body if it worked, or nil if it failed.
  def req(path, args="")
    omegle = Net::HTTP.start(@options[:host])

    # get a return and ignore the errors that
    # occasionally (and seemingly meaninglessly) crop up.
    ret = nil
    begin
      ret = omegle.post("/#{path}", args, STATIC_HEADERS) if args != :get
      ret = omegle.get("/#{path}", STATIC_HEADERS)        if args == :get
    rescue EOFError
    rescue TimeoutError
    end

    # return nil or the content if the call worked
    return ret.body if ret and ret.code == "200"
    return nil
  end

  # Add an event to the FIFO in-order
  def add_events(evts)
    # Accept one event or many
    evts = [evts] if not evts.is_a? Array

    @mx.synchronize{
      # add to front of array, pop off back
      evts.each{|e|
        @events = [e] + @events
      }
    }
  end

  # Returns an 8-character random ID used when connecting.
  # This seems to have no bearing on functionality, but
  # might come in handy, possibly.
  def get_randID()
    # The JS in the omegle page says:
    #  if(!randID||8!==randID.length)
    #     randID=function(){
    #         for(var a="",b=0;8>b;b++)
    #           var c=Math.floor(32*Math.random()),
    #           a=a+"23456789ABCDEFGHJKLMNPQRSTUVWXYZ".charAt(c);
    #           return a
    #   }();
    str = "";
    8.times{ str += "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"[ (rand() * 32).to_i ] }

    return str;
  end

  # Parse a JSON response from omegle,
  # and add its events to the FIFO
  def parse_response(str)
    # win or null don't contain any events, so skip.
    return if str == nil or (%w{win null}.include?(str.to_s.strip))

    # try to parse
    evts = JSON.parse(str)

    # check it's events
    return if not evts.is_a? Array

    # add in order
    add_events(evts)
  end

end
