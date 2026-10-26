# frozen_string_literal: true

module Rails2qdbd
  # Assigns tables to output files (qdbd shows each file as a group) and applies excludes.
  class Grouping
    GLOB_FLAGS = File::FNM_EXTGLOB

    def initialize(config)
      @config = config
    end

    # The first group with a matching glob, else the default group.
    def group_for(table)
      @config.groups.find { |_, globs| matches?(globs, table) }&.first || @config.default_group
    end

    def excluded?(table) = matches?(@config.exclude, table)

    private

    def matches?(globs, table) = globs.any? { |glob| File.fnmatch?(glob, table, GLOB_FLAGS) }
  end
end
