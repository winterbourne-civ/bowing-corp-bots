require "rosegold"

# Stays connected and eats when hungry

SERVER_HOST   = ENV.fetch "SERVER_HOST", "localhost"
SERVER_PORT   = ENV.fetch("SERVER_PORT", "25565").to_i
SPECTATE_HOST = ENV.fetch "SPECTATE_HOST", "0.0.0.0"
SPECTATE_PORT = ENV.fetch("SPECTATE_PORT", "25566").to_i

INITIAL_RETRY_DELAY = 5.seconds
MAX_RETRY_DELAY     = 5.minutes

spectate_server = Rosegold::SpectateServer.new(SPECTATE_HOST, SPECTATE_PORT)
spectate_server.start

retry_delay = INITIAL_RETRY_DELAY

loop do
  begin
    client = Rosegold::Client.new(SERVER_HOST, SERVER_PORT)
    spectate_server.attach_client client
    bot = Rosegold::Bot.new(client)

    bot.join_game
    sleep 3.seconds

    retry_delay = INITIAL_RETRY_DELAY
    puts "Connected successfully!"

    while bot.connected?
      bot.eat!
      bot.wait_ticks 20
    end

    puts "Disconnected, retrying in #{retry_delay.total_seconds} seconds..."
    sleep retry_delay
    retry_delay = [retry_delay * 2, MAX_RETRY_DELAY].min
  rescue e
    puts "Error: #{e.message}, retrying in #{retry_delay.total_seconds} seconds..."
    sleep retry_delay
    retry_delay = [retry_delay * 2, MAX_RETRY_DELAY].min
  end
end
