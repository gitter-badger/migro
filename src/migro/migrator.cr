require "cql"
require "logging"
require "pg"
require "yaml"
require "./migration_file"
require "./migration"

Logging::Config.root_level = Logger::DEBUG

class Migro::Migrator
  include Logging

  getter :database_url
  getter :migrations_dir, :migrations_dir_full_path
  getter :migration_files

  getter :logger
  @migration_files : Array(MigrationFile)
  @migrations : Array(Migration)?

  DEFAULT_MIGRATIONS_DIR = File.join("db", "migrations")
  MIGRATIONS_LOG_TABLE = "database_migrations_log"

  def initialize(@database_url : String, migrations_dir = DEFAULT_MIGRATIONS_DIR, logger = Logger.new(STDOUT))
    @migration_files_dir = migrations_dir
    @logger = logger
    @logger.level = Logger::DEBUG
    @migration_files_dir_full_path = File.expand_path(@migration_files_dir)
    raise %(Path #{@migration_files_dir_full_path} is not a directory!) unless File.directory?(@migration_files_dir_full_path)
    raise %(Path #{@migration_files_dir_full_path} cannot be read!) unless File.readable?(@migration_files_dir_full_path)
    @migration_files = scan_for_migrations
    @database = CQL.connect(@database_url)
  end

  def scan_for_migrations
    Dir.children(@migration_files_dir_full_path).select do |name|
      /^(\d+-)?.+$/ =~ name
    end.map do |name|
      MigrationFile.new(name)
    end.sort
  end

  def migrations : Array(Migration)
    @migrations ||= load_migrations.not_nil!
  end

  def migrations_log : Array(MigrationLog)
    return [] of MigrationLog unless migrations_log_table_exists?
    @database.query_all("SELECT timestamp, filename, checksum FROM #{MIGRATIONS_LOG_TABLE} ORDER BY timestamp") do |rs|
      timestamp, filename, checksum = rs.read(Time, String, String)
      MigrationLog.new(timestamp, filename, checksum)
    end
  end

  def execute
    check_and_ensure_migrations_log_table_exists
    case result = verify_migration_log_integrity
    when Failure
      STDERR.puts result.message
      exit 1
    when Success
      execute_new_migrations
    end
  end

  private def load_migrations
    @migration_files.reduce([] of Migration) do |migrations, migration_file|
      full_path_to_file = File.join(@migration_files_dir_full_path, migration_file.filename)
      case result = Migration.load_from_file(@logger, migration_file, full_path_to_file)
      when Failure
        @logger.error(result.message)
      when Success
        migrations << result.value
      end
      migrations
    end
  end

  MIGRATIONS_LOG_TABLE_DEFINITION = CQL::Table.new(MIGRATIONS_LOG_TABLE).tap do |table|
    table.column "timestamp", CQL::TIMESTAMP, null: false, default: "NOW()"
    table.column "filename", CQL::VARCHAR, size: 120, null: false
    table.column "checksum", CQL::CHAR, size: 32, null: false
  end

  private def check_and_ensure_migrations_log_table_exists
    unless migrations_log_table_exists?
      @database.create_table(MIGRATIONS_LOG_TABLE_DEFINITION).exec
    end
  end

  private def migrations_log_table_exists?
    @database.table_exists?(MIGRATIONS_LOG_TABLE)
  end

  private def verify_migration_log_integrity : Result(Int32)
    logs = migrations_log
    n = logs.size
    (0...n).each do |i|
      log = logs[i]
      file = migrations[i]
      if file.filename != log.filename
        return Result(Int32).failure(%(Missing migration file "#{log.filename}", cowardly refusing to proceed))
      end
      if file.checksum != log.checksum
        return Result(Int32).failure(%(Migration file "#{log.filename}" has changed (expected checksum #{log.checksum} != #{file.checksum}), cowardly refusing to proceed))
      end
      puts "#{Time::Format::ISO_8601_DATE_TIME.format(log.timestamp)} #{log.filename}"
    end
    Result.success(n)
  end

  private def execute_new_migrations
    migrations[migrations_log.size..-1].each do |migration|
      execute_migration(migration)
      record_into_log(migration)
    end
  end

  private def execute_migration(migration)
    migration.changes.each do |change|
      execute_change(change)
    end
    migration.up.each do |change|
      execute_change(change)
    end
  end

  private def execute_change(change : Hash(YAML::Type, YAML::Type))
    debug(change.inspect)
    if change.has_key?("create_table")
      table = CQL::Table.from_yaml(YAML::Any.new(change["create_table"]))
      @database.create_table(table).exec
    elsif change.has_key?("insert")
      execute_insert(YAML::Any.new(change["insert"]))
    end
  end

  private def execute_insert(insert)
    h = insert.as_h
    raise "insert: has no table: name specified!" unless h.has_key?("table")
    table_name = insert["table"].as_s
    return unless h.has_key?("rows")
    rows = insert["rows"].as_a
    rows.each do |row|
      case row
      when Hash(YAML::Type, YAML::Type)
        column_names = row.keys.map(&.to_s)
        values = column_names.map {|key| row[key] }
        @database.insert(table_name).columns(column_names).exec(values)
      else
        raise "Don't know what to do with row of type #{row.class} (expecting Hash)"
      end
    end
  end

  private def record_into_log(migration)
    insert = @database.insert("database_migrations_log").columns("filename", "checksum")
    insert.exec(migration.filename, migration.checksum)
  end
end
