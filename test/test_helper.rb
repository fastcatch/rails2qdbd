# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rails2qdbd"

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "open3"
require "json"

module QdbdHelpers
  ROOT = File.expand_path("..", __dir__)

  # qdbd is a Python tool; prefer the project's .venv, else whatever is on PATH.
  def self.qdbd_bin
    return @qdbd_bin if defined?(@qdbd_bin)

    local = File.join(ROOT, ".venv/bin/qdbd")
    @qdbd_bin = if File.executable?(local)
      local
    else
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
        .map { |dir| File.join(dir, "qdbd") }
        .find { |path| File.executable?(path) }
    end
  end

  def qdbd_bin = QdbdHelpers.qdbd_bin

  # Skips without qdbd, except where REQUIRE_QDBD is set (CI), so those checks cannot vanish silently.
  def require_qdbd!
    return if qdbd_bin

    flunk "qdbd not found but REQUIRE_QDBD is set" unless ["", "0"].include?(ENV.fetch("REQUIRE_QDBD", ""))
    skip "qdbd not installed (run bin/setup)"
  end

  # Runs `qdbd check --strict` on a file or folder; skips when qdbd is unavailable.
  def assert_qdbd_valid(path)
    require_qdbd!
    out, status = Open3.capture2e(qdbd_bin, "check", "--strict", path.to_s)
    assert status.success?, "qdbd check --strict failed:\n#{out}"
  end

  # Compiles text with qdbd's own parser; returns its model as a Hash (tables, relationships,
  # diagnostics). The interpreter is taken from the qdbd script's shebang (.venv or pipx).
  def qdbd_compile(text)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "schema.txt"), text)
      qdbd_compile_dir(dir)
    end
  end

  # Same, for every .txt file in a folder (one shared namespace, as `qdbd check DIR` sees it).
  def qdbd_compile_dir(dir)
    require_qdbd!
    python = File.foreach(qdbd_bin).first.delete_prefix("#!").strip
    files = Dir.glob(File.join(dir, "*.txt")).sort
    out, status = Open3.capture2(python, File.join(ROOT, "test/support/qdbd_compile.py"), *files)
    raise "qdbd compile failed" unless status.success?

    JSON.parse(out)
  end

  # Builds a throwaway app from { "relative/path" => content } and yields its root.
  def with_app(files)
    Dir.mktmpdir do |root|
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), content)
      end
      yield root
    end
  end

  def fixture_path(*parts) = File.join(ROOT, "test/fixtures", *parts)
end

Minitest::Test.include(QdbdHelpers)
