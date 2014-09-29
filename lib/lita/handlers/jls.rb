require "cabin"
require "tmpdir"
require "fileutils"
require "insist"

module Lita
  module Handlers
    class Jls < Handler
      require "lita-jls/util"
      include LitaJLS::Util

      #route /^merge(?<dry>\?)? (?:(?<user>[A-Za-z0-9_-]+)\/)?(?<project>[A-Za-z0-9_-]+)#(?<pr>\d+) (?<branchspec>.*)$/, :merge,
      route /^merge(?<dry>\?)? (?<pr_url>[^ ]+) (?<branchspec>.*)$/, :merge,
        :help => { "merge https://github.com/ORG/PROJECT/pull/NUMBER branch1 [branch2 ...]" => "merges a PR into one or more branches. To see if a merge is successful, use 'merge? project#pr branch1 [branch2 ...]" }
      route /^\(tableflip\)$/, :tableflip, :command => true, :help => { "(tableflip)" => "Fix whatever just broke. Probably git is going funky, so I will purge my local git junk" }

      REMOTE = "origin"
      URLBASE = "https://github.com/"

      on :loaded, :setup

      def self.default_config(config)
        config.default_organization = nil
      end

      def setup(*args)
        ENV["PAGER"] = "cat"
        @@logger_subscription ||= logger.subscribe(STDOUT)
      end

      def merge(msg)
        FileUtils.mkdir_p(workdir) unless File.directory?(workdir)
        #user = msg.match_data["user"] || "elasticsearch"
        #project = msg.match_data["project"]
        #pr = msg.match_data["pr"]
        require "uri"
        pull = msg.match_data["pr_url"]
        pull_path = URI.parse(pull).path
        _, user, project, _, pr = pull_path.split("/")

        if user.nil? || project.nil? || pr.nil? || pull !~ /^https:\/\/github.com\//
          raise "Invalid URL. Expected something like: https://github.com/elasticsearch/snacktime/pull/12345"
        end

        branchspec = msg.match_data["branchspec"]
        dry_run = msg.match_data["dry"]
        p :dry? => dry_run

        url = File.join(URLBASE, user, project)
        #git_url = "git@github.com:/#{user}/#{project}.git"
        git_url = url
        pr_url = File.join(url, "pull", "#{pr}.patch")
        gitpath = gitdir(project)
        branches = branchspec.split(/\s+/)

        logger.info("Cloning git repo", :url => git_url, :gitpath => gitpath)
        repo = clone_at(git_url, gitpath)

        git(gitpath, "am", "--abort") if File.directory?(".git/rebase-apply")
        git(gitpath, "reset", "--hard", "#{REMOTE}/master")
        git(gitpath, "clean", "-f")

        # TODO(sissel): Fetch the PR patch
        logger.info("Fetching PR patch", :url => pr_url)
        http = Faraday.new("https://github.com")
        response = http.get(URI.parse(pr_url).path)
        if !response.success?
          logger.warn("Failed fetching patch", :url => pr_url, :status => response.status, :headers => response.headers)
          msg.reply("Failed fetching patch. Cannot continue!")
          return
        end

        patch = response.body

        # For each branch, try to merge
        repo = Rugged::Repository.new(gitpath)
        branches.each do |branch|
          begin
            logger.info("Switching branches", :branch => branch, :repo => gitpath)
            #repo.checkout(branch)
            git(gitpath, "checkout", branch)
            git(gitpath, "pull", "--ff-only")
            #repo.reset("#{REMOTE}/#{branch}", :mixed)
            git(gitpath, "reset", "#{REMOTE}/#{branch}")
            apply_patch(repo, patch) do |commit|
              # Append the PR number to commit message

              # Use "Fixes #XYZ" to make the PR get closed upon commit.
              # https://help.github.com/articles/closing-issues-via-commit-messages
              commit[:message] += "\nFixes ##{pr}"
            end
          rescue => e
            msg.reply("Failed attempting to merge #{user}/#{project}##{pr}: #{e}")
            raise
          end
        end

        # At this point, all branches merged successfully. Time to push!
        if dry_run
          msg.reply("(success) Merging was successful #{user}/#{project}##{pr} into: #{branchspec}.\n(but I did not push it)")
        else
          msg.reply("(success) #{user}/#{project}##{pr} merged into: #{branchspec}")
          git(gitpath, "push", REMOTE, *branches)

          labels = branches.reject { |b| b == "master" }
          github_issue_label("#{user}/#{project}", pr.to_i, labels)
        end
      rescue => e
        msg.reply("Error: #{e.inspect}")
        raise
      end # def merge

      def tableflip(msg)
        begin
          dir = workdir("gitbase")
          insist { dir } =~ /\/lita-jls/ # Just in case, before we go purging things...
          FileUtils.rm_r(dir)
          msg.reply("git (tableflip) (success)")
        rescue => e
          msg.reply("Git (tableflip) (huh): #{e}")
          raise e
        end
      end
    end # class Jls

    Lita.register_handler(Jls)
  end
end
