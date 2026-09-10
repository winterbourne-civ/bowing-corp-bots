require "rosegold"
Rosegold::Client.protocol_version = 774_u32 # 1.21.11
# Harvests a rectangular pumpkin field

SERVER_HOST   = ENV.fetch "SERVER_HOST", "play.civmc.net"
SPECTATE_HOST = ENV.fetch "SPECTATE_HOST", "0.0.0.0"
SPECTATE_PORT = ENV.fetch("SPECTATE_PORT", "25566").to_i

X_EAST  = -1137
X_WEST  = -1471
Z_NORTH = -7430
Z_SOUTH = -7308

COMPACTOR_STAND_X   = -1471
COMPACTOR_STAND_Z   = -7308
COMPACTOR_CHEST_X   = -1469
COMPACTOR_CHEST_Z   = -7307
COMPACTOR_FURNACE_X = -1473
COMPACTOR_FURNACE_Z = -7307

DISCORD_GROUP    = "FU-Bot"
FARM_NAME        = "Pumpkin Farm in Fyri"
REGROW_HOURS     = 32
PITCH_GOAL       = 18.0_f32
PITCH_SETTLE_EPS =  5.0_f32

STICK_HOTBAR_SLOT = 9_u8 # 1-indexed: slot 8 in the original
HARVEST_TOOLS     = ["diamond_axe"]

ROW_STEP = 4

class PumpkinFarmer
    getter bot : Rosegold::Bot
 
    @row : Int32 = 0
    @dir : Int32 = 1 # 1 = north (yaw 180, decreasing z), 0 = south (yaw 0, increasing z)
    @start_time : Time
 
    @avg_pass_seconds : Float64 = 180.0
    @passes_completed : Int32 = 0
 
    def initialize(@bot : Rosegold::Bot)
        @start_time = Time.utc
    end
 
    def start
        cur_x = bot.x.floor.to_i
        cur_z = bot.z.floor.to_i
        unless (X_WEST..X_EAST).includes?(cur_x) && (Z_NORTH..Z_SOUTH).includes?(cur_z)
            Log.warn { "Not inside beetroot farm bounds (#{cur_x}, #{cur_z}); aborting" }
            return
        end
 
        pick_harvest_tool
        farm_main
        finish
    end
 
    private def pick_harvest_tool
        found = HARVEST_TOOLS.any? { |name| bot.inventory.pick(name) }
        raise "No more usable harvest tools in inventory" unless found
    end
 
    private def pick_stick
        found = bot.inventory.pick("stick")
        raise "No sticks left in inventory to light the furnace" unless found
    end
 
    private def record_pass_duration(seconds : Float64)
        @passes_completed += 1
        @avg_pass_seconds += (seconds - @avg_pass_seconds) / @passes_completed
    end
 
    private def farm_two_lines
        farm_line
 
        cur_x = bot.x.floor.to_f
        cur_z = bot.z.floor.to_f
        bot.move_to(cur_x, cur_z - 0.5)
 
        @row += 1
        @dir = 1 - @dir
        farm_line
 
        resume_x = bot.x.floor.to_f
 
        compact
        
        cur_z = bot.z.floor.to_f
        bot.move_to(resume_x, cur_z)
 
        @row += 3
        bot.move_to(cur_x, Z_SOUTH.to_f64 + 0.5)
        bot.move_to(cur_x + 4, Z_SOUTH.to_f64 + 0.5)
        @dir = 1 - @dir
    end
 
    private def farm_line
        start_z = @dir == 1 ? Z_SOUTH : Z_NORTH
        bot.move_to(@row, start_z)
 
        yaw = @dir == 1 ? 180.0_f32 : 0.0_f32
        bot.look = Rosegold::Look.new(yaw, 90.0_f32)
        bot.start_digging
 
        pitch = 90.0_f32
        while (pitch - PITCH_GOAL).abs > PITCH_SETTLE_EPS
            bot.wait_tick
            pitch += (PITCH_GOAL - pitch) / 10.0_f32
            bot.look = Rosegold::Look.new(yaw, pitch)
        end
 
        keep_picking = true
        spawn do
            while keep_picking && bot.connected?
                bot.wait_ticks 4
                pick_harvest_tool rescue nil
            end
        end
 
        bot.sneak
        bot.keys.press Rosegold::MovementKeys::Key::Forward
        begin
            loop do
                bot.wait_tick
                pitch += (PITCH_GOAL - pitch) / 10.0_f32
                bot.look = Rosegold::Look.new(yaw, pitch)
 
                if @dir == 1
                    break if bot.z.floor < Z_NORTH + 4
                else
                    break if bot.z.floor > Z_SOUTH - 4
                end
            end
        ensure
            keep_picking = false
        end
 
        bot.keys.release Rosegold::MovementKeys::Key::Forward
        bot.sneak false
        bot.stop_digging
        bot.wait_ticks 7
    end
 
    # Walk to the compactor pad, deposit pumpkins in the chest, then light
    # the furnace by hitting it with a stick.
    private def compact
        bot.move_to(COMPACTOR_STAND_X, COMPACTOR_STAND_Z)
 
        chest_target = Rosegold::Vec3d.new(COMPACTOR_CHEST_X + 0.5, bot.y + 2.5, COMPACTOR_CHEST_Z + 0.5)
        bot.look_at chest_target
        bot.wait_ticks 7
 
        bot.open_container do
            bot.wait_ticks 5
            bot.inventory.deposit_at_least(2048, "pumpkin")
            bot.wait_ticks 5
        end
        bot.wait_ticks 7
 
        furnace_target = Rosegold::Vec3d.new(COMPACTOR_FURNACE_X + 0.5, bot.y + 2.5, COMPACTOR_FURNACE_Z + 0.5)
        bot.look_at furnace_target
        pick_stick
        bot.wait_ticks 7
        bot.attack
        bot.wait_ticks 7
 
        pick_harvest_tool
    end
 
    private def farm_main
        @row = bot.x.floor.to_i
        Log.info { "Resuming at column #{@row - X_WEST}" } if @row != X_WEST
 
        while @row <= X_EAST
        remaining_passes = ((X_EAST - @row).to_f / ROW_STEP).ceil.to_i + 1
        eta = (remaining_passes * @avg_pass_seconds).to_i
        Log.info { "#{remaining_passes} passes remaining (~#{eta // 60}m #{eta % 60}s, avg #{@avg_pass_seconds.round(1)}s/pass)" }
 
        pass_start = Time.utc
        farm_two_lines
        record_pass_duration((Time.utc - pass_start).total_seconds)
        end
    end
 
    private def finish
        seconds = (Time.utc - @start_time).total_seconds.to_i
        minutes, seconds = seconds.divmod(60)
        bot.chat "/g #{DISCORD_GROUP} #{FARM_NAME} is finished to harvest in #{minutes} minutes and #{seconds} seconds. It'll be ready again in #{REGROW_HOURS} hours. Now logging out"
        bot.chat "/logout"
    end
end
 
# spectate_server = Rosegold::SpectateServer.new(SPECTATE_HOST, SPECTATE_PORT)
# spectate_server.start
 
# client = Rosegold::Client.new SERVER_HOST
# spectate_server.attach_client client
# bot = Rosegold::Bot.new(client)
# bot.join_game
# sleep 3.seconds
 
# puts "Connected, waiting for spectator"
 
# until spectate_server.connections.size > 0
#     sleep 100.milliseconds
# end
 
# puts "Spectator connected, starting farm"
# PumpkinFarmer.new(bot).start

spectate_server = Rosegold::SpectateServer.new(SPECTATE_HOST, SPECTATE_PORT)
spectate_server.start

client = Rosegold::Client.new SERVER_HOST
spectate_server.attach_client client
bot = Rosegold::Bot.new(client)
bot.join_game
sleep 3.seconds

Log.info { "Connected, starting beetroot farm" }
PumpkinFarmer.new(bot).start