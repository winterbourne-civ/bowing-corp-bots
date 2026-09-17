require "rosegold"
Rosegold::Client.protocol_version = 774_u32 # 1.21.11
# Harvests a rectangular beetroot field by walking row-by-row, drops surplus
# beetroot seeds, and periodically deposits beetroot in a chest and lights a
# stick-fired furnace compactor. Adapted from arthirob's jsmacros script (v1.0).

SERVER_HOST   = ENV.fetch "SERVER_HOST", "play.civmc.net"
SPECTATE_HOST = ENV.fetch "SPECTATE_HOST", "0.0.0.0"
SPECTATE_PORT = ENV.fetch("SPECTATE_PORT", "25566").to_i

X_EAST  = -1135
X_WEST  = -1335
Z_NORTH = -7432
Z_SOUTH = -7226

COMPACTOR_STAND_X   = -1184
COMPACTOR_STAND_Z   = -7430
COMPACTOR_CHEST_X   = -1185
COMPACTOR_CHEST_Z   = -7432
COMPACTOR_FURNACE_X = -1183
COMPACTOR_FURNACE_Z = -7432

DISCORD_GROUP   = "FU-Bot"
FARM_NAME       = "Beetroot farm south of Moscow"
REGROW_HOURS    = 32
PITCH_GOAL      = 15.0_f32
PITCH_SETTLE_EPS =  5.0_f32
LINES_PER_COMPACT = 5

HARVEST_HOTBAR_SLOT =  1_u8 # 1-indexed: slot 0 in the original
STICK_HOTBAR_SLOT   =  9_u8 # 1-indexed: slot 8 in the original

QUEUE_CHECK_COMMAND     = "/spawn"
UNKNOWN_COMMAND_MESSAGE = "Unknown or incomplete command"

class BeetrootFarmer
  getter bot : Rosegold::Bot

  @row : Int32 = 0
  @dir : Int32 = 1 # 1 = north (yaw 180, decreasing z), 0 = south (yaw 0, increasing z)
  @lines_since_compact : Int32 = 0
  @start_time : Time

  def initialize(@bot : Rosegold::Bot)
    @start_time = Time.utc
  end

  def start
    wait_until_in_main

    cur_x = bot.x.floor.to_i
    cur_z = bot.z.floor.to_i
    unless (X_WEST..X_EAST).includes?(cur_x) && (Z_NORTH..Z_SOUTH).includes?(cur_z)
      Log.warn { "Not inside beetroot farm bounds (#{cur_x}, #{cur_z}); aborting" }
      return
    end

    bot.hotbar_selection = HARVEST_HOTBAR_SLOT
    farm_main
    finish
  end

  private def wait_until_in_main(check_interval : Time::Span = 1.minutes, response_timeout : Time::Span = 5.seconds)
    until in_main_server?(response_timeout)
        sleep check_interval
    end
    Log.info { "Logged into main" }
    bot.wait_ticks 20
  end

  private def in_main_server?(response_timeout : Time::Span) : Bool
      got_unknown_command = false

      handler_id = bot.on Rosegold::Clientbound::SystemChatMessage do |event|
          msg = event.message.to_s.gsub(/§[0-9a-fk-or]/, "").strip
          got_unknown_command = true if msg.includes?(UNKNOWN_COMMAND_MESSAGE)
      end

      bot.chat QUEUE_CHECK_COMMAND

      timeout_time = Time.utc + response_timeout
      while !got_unknown_command && Time.utc < timeout_time
          sleep 0.1.seconds
      end

      bot.off Rosegold::Clientbound::SystemChatMessage, handler_id
      got_unknown_command
  end

  private def pick_stick
    found = bot.inventory.pick("stick")
    raise "No sticks left in inventory to light the furnace" unless found
  end

  private def farm_main
    @row = bot.x.floor.to_i
    Log.info { "Resuming at column #{@row - X_WEST}" } if @row != X_WEST

    while @row <= X_EAST
      remaining = X_EAST - @row + 1
      eta = (remaining * time_per_row).to_i
      Log.info { "#{remaining} columns remaining (~#{eta // 60}m #{eta % 60}s)" }
      farm_two_lines
    end
  end

  private def time_per_row
    (Z_SOUTH - Z_NORTH) / 4.31 + 3
  end

  private def farm_two_lines
    farm_line
    @row += 1
    @dir = 1 - @dir
    farm_line
    @row += 1
    @dir = 1 - @dir

    @lines_since_compact += 2
    drop_seeds

    if @lines_since_compact >= LINES_PER_COMPACT
      compact
      @lines_since_compact = 0
    end
  end

  # Walks one column south↔north (depending on @dir), pitched slightly down with
  # the use button held — server harvests crops as they pass under the cursor.
  private def farm_line
    start_z = @dir == 1 ? Z_SOUTH : Z_NORTH
    bot.move_to(@row, start_z)

    yaw = @dir == 1 ? 180.0_f32 : 0.0_f32
    bot.look = Rosegold::Look.new(yaw, 90.0_f32)
    bot.start_using_hand

    pitch = 90.0_f32
    while (pitch - PITCH_GOAL).abs > PITCH_SETTLE_EPS
      bot.wait_tick
      pitch += (PITCH_GOAL - pitch) / 10.0_f32
      bot.look = Rosegold::Look.new(yaw, pitch)
    end

    bot.keys.press Rosegold::MovementKeys::Key::Forward
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

    bot.keys.release Rosegold::MovementKeys::Key::Forward
    bot.stop_using_hand
    bot.wait_ticks 7
  end

  private def drop_seeds
    bot.look = Rosegold::Look.new(90.0_f32, 0.0_f32)
    while bot.inventory.count("beetroot_seeds") > 0 && bot.connected?
      bot.inventory.throw_all_of("beetroot_seeds")
      bot.wait_ticks 5
    end
  end

  # Walk to the compactor pad, deposit beetroot in the chest, then attack the
  # furnace with a stick to light the smelt.
  private def compact
    bot.move_to(COMPACTOR_STAND_X, COMPACTOR_STAND_Z)

    # Chest sits two blocks above the bot's feet, so look up at it.
    chest_target = Rosegold::Vec3d.new(COMPACTOR_CHEST_X + 0.5, bot.y + 2.5, COMPACTOR_CHEST_Z + 0.5)
    bot.look_at chest_target
    bot.wait_ticks 7

    bot.open_container do
      bot.wait_ticks 5
      bot.inventory.deposit_at_least(2048, "beetroot")
      bot.wait_ticks 5
    end
    bot.wait_ticks 7

    furnace_target = Rosegold::Vec3d.new(COMPACTOR_FURNACE_X + 0.5, bot.y + 2.5, COMPACTOR_FURNACE_Z + 0.5)
    bot.look_at furnace_target
    pick_stick
    bot.wait_ticks 7
    bot.attack
    bot.wait_ticks 7
    bot.hotbar_selection = HARVEST_HOTBAR_SLOT
  end

  private def finish
    seconds = (Time.utc - @start_time).total_seconds.to_i
    minutes, seconds = seconds.divmod(60)
    bot.chat "/g #{DISCORD_GROUP} #{FARM_NAME} is finished to harvest in #{minutes} minutes and #{seconds} seconds. It'll be ready again in #{REGROW_HOURS} hours. Now logging out"
    bot.chat "/logout"
  end
end

spectate_server = Rosegold::SpectateServer.new(SPECTATE_HOST, SPECTATE_PORT)
spectate_server.start

client = Rosegold::Client.new SERVER_HOST
spectate_server.attach_client client
bot = Rosegold::Bot.new(client)
bot.join_game
sleep 3.seconds

Log.info { "Connected, starting beetroot farm" }
BeetrootFarmer.new(bot).start
