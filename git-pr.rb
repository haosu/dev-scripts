# !/usr/bin/env ruby


require 'octokit'
require 'tempfile'

Octokit.configure do |config|
  config.access_token = ENV.fetch('GITHUB_TOKEN')
  config.api_endpoint = ENV.fetch('GITHUB_API_URL', 'https://github.bus.zalan.do//api/v3')
end

###########
# sqlite functions

SQLITE_PREFIX = "sqlite3 .git/github.sqlite3"

TITLE_MARKER = '<!-- ENTER PULL REQUEST TITLE BELOW -->'
SUMMARY_MARKER = '<!-- SUMMARIZE PULL REQUEST BELOW -->'
AUTOGEN_MARKER = '<!-- The following text is auto-generated from your commit messages -->'

# Conditional table creation
def init_db
  create_sql_string = "CREATE TABLE IF NOT EXISTS pull_requests ( branch_name string PRIMARY KEY, pull_request_number int NOT NULL);"

  execute!(
    "#{SQLITE_PREFIX} \"#{create_sql_string}\""
  )
end

def local_pull_request_id
  init_db

  get_sql_string = "SELECT pull_request_number FROM pull_requests"

  `#{SQLITE_PREFIX} \"#{get_sql_string}\"`
end

def save_pull_request(branch_name, pr_id)
  init_db

  save_sql_string =
    "INSERT OR REPLACE INTO pull_requests (branch_name, pull_request_number) VALUES ('#{branch_name}', #{pr_id})"

  execute!(
    "#{SQLITE_PREFIX} \"#{save_sql_string}\""
  )
end

###########
# git functions

def repo_name
  return @repo_name if @repo_name
  _, repo = remote_git_url.split(':')

  @repo_name = repo.gsub(/\.git$/, '')
end

def pull_request_url(pr_id)
  domain, _ = remote_git_url.split(':')

  "https://#{domain}/#{repo_name}/pull/#{pr_id}"
end

def repo_root
  `git rev-parse --show-toplevel`.chomp
end

def remote_git_url
  @remote_git_url = `git remote get-url origin`.chomp.split('@', 2)[1]
end

def validate_local_branch
  if local_branch == 'master'
    puts 'Cannot open a pull request against remote `master` branch while on local `master` branch!'
    puts 'Rename your local branch to a feature branch'
    exit 1
  end
end

def local_branch
  @local_branch ||= `git rev-parse --abbrev-ref HEAD`.chomp
end

def commits_ahead_of_base(base)
  `git log --oneline --pretty=%H #{base}..HEAD`.split("\n")
end

def commit_subject(commit_hash)
  `git log #{commit_hash} --pretty=%s --max-count=1`.rstrip
end

def remote_branch(local_branch_name)
  `git config branch.#{local_branch_name}.merge | sed 's/^refs\\/heads\\///'`.chomp
end

def remote(local_branch_name)
  `git config branch.#{local_branch_name}.remote | sed 's/^refs\\/heads\\///'`.chomp
end

# Generate summary of commits in Markdown format so it is easy to read in the PR
def generate_pull_request_title_and_body(domain, repo, base_ref, head: 'HEAD', title: nil, summary: nil, body: nil)
  # Extract existing summary if there is one
  match = body&.match(/#{SUMMARY_MARKER}(?<summary>.*?)#{AUTOGEN_MARKER}/m)
  if !summary && match
    summary = match['summary'].strip
    summary = nil if summary.empty?
  end

  pr_body =
    "#{TITLE_MARKER}\n" \
    "#{title}\n" \
    "#{SUMMARY_MARKER}\n" \
    "#{summary}\n" \
    "#{AUTOGEN_MARKER}\n" \
    "### Commit Summary\n" +
    `git log \
    --reverse \
    --pretty="#### [%s](https://#{domain}/#{repo}/commit/%H)%n%b%n---" \
    "#{base_ref}..#{head}"`

  body = edit_string_with_editor(pr_body)

  # Extract new title if there is one
  match = body&.match(/#{TITLE_MARKER}(?<title>.*?)#{SUMMARY_MARKER}/m)
  if match
    title = match['title'].strip
    title = nil if title.empty?
  end

  # Remove the title from the body since it is stored separately
  body.gsub!(/#{TITLE_MARKER}(?:.*?)(#{SUMMARY_MARKER})/m, '\\1')

  [title, body]
end

###########
# System functions

def execute!(cmd)
  unless system(cmd)
    raise RuntimeError, "Command `#{cmd}` failed"
  end
end

def edit_string_with_editor(string)
  unless ENV.key?('EDITOR')
    raise 'EDITOR environment variable must be set!'
  end
  tmp = Tempfile.new(['pull-request-body', '.md']).tap do |file|
    file.write(string)
    file.fsync
    loop do
      break if system(ENV['EDITOR'], file.path)
      if ask('Editor exited unsuccessfully. Try again? (y/n)', 'y').to_s.strip.downcase != 'y'
        raise 'User canceled'
      end
    end
  end
  File.read(tmp.path)
end

###########
# github functions

def client
  @client ||= Octokit::Client.new
end

def get_associated_prs
  client.pull_requests(repo_name)
end

def push_feature_branch(remote, local_branch)
  system("git push --force #{remote == '.' ? 'origin' : remote} #{local_branch}")
end

##########
# Script functions

def pretty_print_prs(prs)
  prs.each_with_index do |pr, idx|
    puts "#{idx})\t#{pr.title[0..30]}..."
  end
end

#############
# Command handlers

def handle_list
  pretty_print_prs(
    get_associated_prs
  )
end

def handle_browse_pr(idx)
  execute!(
    "open #{get_associated_prs[idx].html_url}"
  )
end

def handle_view
  pr_url = pull_request_url(local_pull_request_id)
  puts "Navigating to #{pr_url}"

  execute!(
    "open #{pr_url}"
  )
end

def handle_create(use_master = false)
  remote_branch = remote_branch(local_branch)
  remote = remote(local_branch)
  base_ref =
    if remote_branch.strip.empty? || use_master
      'master'
    else
      remote_branch
    end

  commits = commits_ahead_of_base(base_ref)

  if commits.empty?
    puts "You are zero commits ahead of #{base_ref}."
    puts "Did you forget to commit or switch to your feature branch?"
    exit 1
  end

  pull_request_id = local_pull_request_id

  domain, _ = remote_git_url.split(':')
  repo = repo_name

  if pull_request_id
    pr = Octokit.pull_request(repo, pull_request_id)
    title, body = generate_pull_request_title_and_body(domain, repo, base_ref,
                                                       title: pr.title, body: pr.body)
    if push_feature_branch(remote, local_branch)
      Octokit.update_pull_request(repo, pr.number, title: title, body: body)
    end
  else
    pull_request_template_path = File.join(repo_root, '.github', 'PULL_REQUEST_TEMPLATE.md')
    summary =
      if File.exist?(pull_request_template_path)
        File.read(pull_request_template_path)
      end

    title = commit_subject(commits.last) # Use first commit in chain as default title
    title, body = generate_pull_request_title_and_body(domain, repo, base_ref, title: title, summary: summary)
    if push_feature_branch(remote, local_branch)
      pr = Octokit.create_pull_request(repo, base_ref, local_branch, title, body)
      save_pull_request(local_branch, pr.number)
    end
  end
end

valid_commands = %w[create merge view list]

command = ARGV.first
command_args = ARGV[1..-1]

unless valid_commands.include?(command)
  puts "Invalid command '#{command}'; must be one of: #{valid_commands.join('/')}"
  exit 1
end

case command
when 'create'
  use_master = command_args.first
  if (use_master == 'master')
    handle_create(true)
  else
    handle_create
  end
when 'view'
  handle_view
when 'list'
  pr_index = command_args.first
  if(pr_index)
    handle_browse_pr(pr_index.to_i)
  else
    handle_list
  end
end
