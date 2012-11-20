# ~*~ encoding: utf-8 ~*~
require 'cgi'
require 'sinatra'
require 'gollum'
require 'mustache/sinatra'
require 'useragent'
require 'stringex'

require 'gollum/frontend/views/layout'
require 'gollum/frontend/views/editable'
require 'gollum/frontend/views/has_page'

require File.expand_path '../helpers', __FILE__

# Fix to_url
class String
  alias :upstream_to_url :to_url
  # _Header => header which causes errors
  def to_url
    return nil if self.nil?
    return self if ['_Header', '_Footer', '_Sidebar'].include? self
    upstream_to_url
  end
end

# Run the frontend, based on Sinatra
#
# There are a number of wiki options that can be set for the frontend
#
# Example
# require 'gollum/frontend/app'
# Precious::App.set(:wiki_options, {
#     :universal_toc => false,
# }
#
# See the wiki.rb file for more details on wiki options
module Precious
  class App < Sinatra::Base
    register Mustache::Sinatra
    include Precious::Helpers

    dir = File.dirname(File.expand_path(__FILE__))

    # Detect unsupported browsers.
    Browser = Struct.new(:browser, :version)

    @@min_ua = [
        Browser.new('Internet Explorer', '10.0'),
        Browser.new('Chrome', '7.0'),
        Browser.new('Firefox', '4.0'),
    ]

    def supported_useragent?(user_agent)
      ua = UserAgent.parse(user_agent)
      @@min_ua.detect {|min| ua >= min }
    end

    # We want to serve public assets for now
    set :public_folder, "#{dir}/public/gollum"
    set :static,         true
    set :default_markup, :markdown

    set :mustache, {
      # Tell mustache where the Views constant lives
      :namespace => Precious,

      # Mustache templates live here
      :templates => "#{dir}/templates",

      # Tell mustache where the views are
      :views => "#{dir}/views"
    }

    # Sinatra error handling
    configure :development, :staging do
      enable :show_exceptions, :dump_errors
      disable :raise_errors, :clean_trace
    end

    configure :test do
      enable :logging, :raise_errors, :dump_errors
    end

    before do
      @base_url = url('/', false).chomp('/')
      # above will detect base_path when it's used with map in a config.ru
      settings.wiki_options.merge!({ :base_path => @base_url })
    end

    get '/' do
      redirect ::File.join(@base_url, 'Home')
    end

    # path is set to name if path is nil.
    #   if path is 'a/b' and a and b are dirs, then
    #   path must have a trailing slash 'a/b/' or
    #   extract_path will trim path to 'a'
    # name, path, version
    def wiki_page(name, path = nil, version = nil, exact = true)
      path = name if path.nil?
      name = extract_name(name)
      path = extract_path(path)
      path = '/' if exact && path.nil?

      wiki = wiki_new

      OpenStruct.new(:wiki => wiki, :page => wiki.paged(name, path, exact, version),
                     :name => name, :path => path)
    end

    def wiki_new
      Gollum::Wiki.new(settings.gollum_path, settings.wiki_options)
    end

    get %r{^/(javascript|css|images)} do
      halt 404
    end

    get %r{/(.+?)/([0-9a-f]{40})} do
      file_path = params[:captures][0]
      version   = params[:captures][1]
      wikip     = wiki_page(file_path, file_path, version)
      name      = wikip.name
      path      = wikip.path
      if page = wikip.page
        @page = page
        @name = name
        @content = page.formatted_data
        @editable = false
        mustache :page
      else
        halt 404
      end
    end

    get '/search' do
      @query = params[:q]
      wiki = wiki_new
      # Sort wiki search results by count (desc) and then by name (asc)
      @results = wiki.search(@query).sort{ |a, b| (a[:count] <=> b[:count]).nonzero? || b[:name] <=> a[:name] }.reverse
      @name = @query
      mustache :search
    end

    get '/*' do
      show_page_or_file(params[:splat].first)
    end

    def show_page_or_file(fullpath)
      name         = extract_name(fullpath)
      path         = extract_path(fullpath) || '/'
      wiki         = wiki_new

      page_dir = settings.wiki_options[:page_file_dir].to_s
      path = ::File.join(page_dir, path) unless path.start_with?(page_dir)

      if page = wiki.paged(name, path, exact = true)
        @page = page
        @name = name
        @editable = false
        @content = page.formatted_data
        @toc_content = wiki.universal_toc ? @page.toc_data : nil
        @mathjax = wiki.mathjax
        @css = wiki.css
        @h1_title = wiki.h1_title
        mustache :page
      elsif file = wiki.file(fullpath)
        content_type file.mime_type
        file.raw_data
      else
        page_path = [path, name].compact.join('/')
        halt 404
      end
    end

    def update_wiki_page(wiki, page, content, commit, name = nil, format = nil)
      return if !page ||
        ((!content || page.raw_data == content) && page.format == format)
      name    ||= page.name
      format    = (format || page.format).to_sym
      content ||= page.raw_data
      wiki.update_page(page, name, format, content.to_s, commit)
    end

    private

    # Options parameter to Gollum::Committer#initialize
    #     :message   - The String commit message.
    #     :name      - The String author full name.
    #     :email     - The String email address.
    # message is sourced from the incoming request parameters
    # author details are sourced from the session, to be populated by rack middleware ahead of us
    def commit_message
      commit_message = { :message => params[:message] }
      author_parameters = session['gollum.author']
      commit_message.merge! author_parameters unless author_parameters.nil?
      commit_message
    end
  end
end