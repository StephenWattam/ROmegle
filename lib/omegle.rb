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

##
# Open, manage and use a Session with Omegle.
#
# This class is capable of supporting all Omegle features, except webcam support, and constitutes a fairly thin layer over Omegle's event system.
# 
# Each time the code interacts with Omegle's web services, it receives, and queues up, some events.  These events may then be accessed in a thread-safe manner using the various functions of the class.
# These events are documented, but only loosely.  They fit into rough categories:
# 
# * General events: waiting, connected, gotMessage, strangerDisconnected, typing, stoppedTyping, recaptchaRequired, recaptchaRejected, count, antinudeBanned
# * Spy Mode Events: spyMessage, spyTyping, spyStoppedTyping, spyDisconnected, question, error, commonLikes
# 
# You'll have to do some testing to verify the precise pattern you receive when doing things, as Omegle seem to change some of their events around from time to time.
class Omegle

  ##
  # Passed to omegle in every call.
  #
  # By default the static headers simply set the referer.
  STATIC_HEADERS = {"referer" => "http://omegle.com"}

  ##
  # Default options.  These run to:
  # * :host --- String, the host to connect to (don't change from omegle.com unless you wish to defy their load balancer)
  # * :question --- String, the question to ask in spy mode
  # * :topics --- Array of Strings, the list of topics you're interested in for Omegle's topic matching
  # * :answer --- Boolean, tell Omegle that you wish to be watched (i.e. take part in spy mode for someone else's question)
  # * :headers --- Some HTTP headers to send with every call, handy for things like user agent spoofing.
  #
  # Setting :question, :topics, or :answer will set the 'mode' of the session, and will cause errors if two are
  # set together.
  DEFAULT_OPTIONS = {:host     => 'omegle.com',
                     :question => nil,
                     :topics   => nil,
                     :answer   => false,
                     :headers  => STATIC_HEADERS}

  # The ID of this session
  attr_accessor :id

  # Construct the Omegle object and set options 
  # See #DEFAULT_OPTIONS for a list of valid options for the hash.
  def initialize(options = {})
    # mutex for multiple access to send/events
    @mx = Mutex.new
    @options = DEFAULT_OPTIONS

    # Load and validate config options
    integrate_configs(options)

    # FIFO for events
    @events = []
  end

  # :category: Control
  #
  # Static construct/use method.
  #
  # The code below:
  #
  #  Omegle.start(options){
  #     whatever
  #  }
  #
  # is equivalent to calling
  #  o = Omegle.new(options)
  #  o.start
  #  whatever
  #  o.disconnect
  #
  def self.start(options = {})
    s = Omegle.new(options)
    s.start
    yield s
    s.disconnect
  end

  # :category: Control
  #
  # Make the initial request to omegle to start the session.
  #
  # This will, like all other calls to Omegle, cause some events to pile up.
  # See #DEFAULT_OPTIONS for a list of valid options for the hash.
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

  # :category: Control
  #
  # Check omegle to see if any events have come through.
  def poll_events
    ret = req('events', "id=#{@id}")
    parse_response(ret)
  end

  # :category: Control
  #
  # Send a message to whoever is connected (if, indeed, they are)
  def send(msg)
    ret = req('send', "id=#{@id}&msg=#{URI::encode(msg)}")
    parse_response(ret)
  end

  # :category: Control
  #
  # Let them know you're typing.
  def typing
    ret = req('typing', "id=#{@id}")
    parse_response(ret)
  end

  # :category: Control
  #
  # Disconnect from Omegle.
  #
  # This merely requests a disconnect.  Omegle will then stop issuing events,
  # which will cause any calls to get_event to return nil, which will in turn
  # cause listen to quit.
  def disconnect
    ret = req('disconnect', "id=#{@id}")
    @id = nil if ret != nil
    parse_response(ret)
  end

  # :category: Status
  #
  # Is this object in a session?
  def connected?
    @id != nil
  end

  # :category: Status
  #
  # Is spy mode on?
  def spy_mode?
    @options[:question] != nil
  end

  # :category: Status
  #
  # Does this session have any topics associated?
  def topics
    @options[:topics]
  end

  # :category: Events
  #
  # Pass a code block to deal with each events as they come.
  #
  # This continually returns events until the omegle session is
  # disconnected, and is the main way of interacting with the thing.
  def listen
    # Get any events since last call
    poll_events

    # repeatedly yield any incoming events,
    # and keep polling. 
    #
    # This drops out when no events are
    # available, and automatically polls for more
    while (e = get_event) != nil
      yield e
      poll_events if @events.length == 0
    end
  end

  # :category: Events
  #
  # Returns the oldest event from the FIFO
  #
  # This, unlike #peek_event removes the event from the list.
  def get_event
    @mx.synchronize{
      return @events.pop
    } 
  end

  # :category: Events
  #
  # Returns a reference to the oldest event on the FIFO.
  #
  # Unlike #get_event this does not remove it from the list.
  def peek_event
    @mx.synchronize{
      return @events.last
    }
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
  #
  # Arguments:
  #   path: The page to request, without trailing or preceeding slash (i.e. 'status' for 'omegle.com/status')
  #   args: A list of URI-formatted arguments, or the :get symbol
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
