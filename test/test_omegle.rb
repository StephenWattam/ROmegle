require 'test/unit'
require 'romegle'

# This is a very imperfect test pack, but it serves as a better test than none at all.
class OmegleTest < Test::Unit::TestCase

  def test_spy_mode
    puts "Testing Spy Mode"
    puts "----------------"
    puts "You should see:"
    puts " 1) Successful connection"
    puts " 2) Spy-related events"
    puts " 3) Clean disconnection"
    puts ""

    o = pullup(:question => "What flavour is blue?")
    
    # then dump events to stdout
    puts "Starting event handler..."
    o.listen{|e|
      puts "Event: #{e}"
    }

    puts "Disconnecting..."
    o.disconnect
    puts "Done."
  end


  def test_conversation
    puts "Testing Normal conversation mode"
    puts "--------------------------------"
    puts "You should see:"
    puts " 1) Successful connection"
    puts " 2) Talking events (one send, zero or more receives)"
    puts " 3) Successful d/c"
    puts ""

    o = pullup()

    sent = false;
    o.listen{|e|
      if not sent
        o.send("Apologies, but I must be going, Goodbye!") 
        sent = true
      end
    }

    o.disconnect
  end

  def pullup(options = {})
    puts "Instantiating..."
    o = Omegle.new(options)
    
    puts "Connecting to Omegle..."
    o.start

    return o
  end
end
