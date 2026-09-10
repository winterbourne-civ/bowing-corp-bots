require "rosegold"

bot = Rosegold::Bot.join_game(ENV.fetch("SERVER_HOST", "play.civmc.net"))
puts "Conected. Health: #{bot.health}, pos: #{bot.x}, #{bot.y}, #{bot.z}"
sleep 60.seconds