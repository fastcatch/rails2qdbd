# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

task default: :test

FIXTURE_APPS = FileList["test/fixtures/apps/*"].select { |dir| File.directory?(dir) }

desc "Regenerate the golden qdbd files of the fixture apps (review the diff before committing)"
task :golden do
  FIXTURE_APPS.each do |app|
    sh RbConfig.ruby, "-Ilib", "exe/rails2qdbd", app, "-o", File.join(app, "expected"), "-q"
  end
end
