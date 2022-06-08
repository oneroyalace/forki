# frozen_string_literal: true

# require_relative "user_scraper"
require "capybara/dsl"
require "dotenv/load"
require "oj"
require "selenium-webdriver"
require "open-uri"
 
options = Selenium::WebDriver::Chrome::Options.new
options.add_argument("--window-size=1400,1400")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.add_argument("--user-data-dir=/tmp/tarun")


Capybara.register_driver :chrome do |app|
  client = Selenium::WebDriver::Remote::Http::Default.new
  client.read_timeout = 10  # Don't wait 60 seconds to return Net::ReadTimeoutError. We'll retry through Hypatia after 10 seconds
  Capybara::Selenium::Driver.new(app, browser: :chrome, url: "http://localhost:4444/wd/hub", capabilities: options, http_client: client)
end

# Capybara.default_driver = :selenium_chrome
Capybara.default_max_wait_time = 15
Capybara.threadsafe = true
Capybara.reuse_server = true
Capybara.app_host = "https://facebook.com"

module Forki
  class Scraper
    include Capybara::DSL

    @@logger = Logger.new(STDOUT)
    @@logger.level = Logger::WARN

    def initialize
      Capybara.default_driver = :chrome
    end

    # Yeah, just use the tmp/ directory that's created during setup
    def download_image(img_elem)
      img_data = URI.open(img_elem["src"]).read
      File.binwrite("temp/emoji.png", img_data)
    end

    # Returns all GraphQL data objects embedded within a string
    # Finds substrings that look like '"data": {...}' and converts them to hashes
    def find_graphql_data_strings(objs = [], html_str)
      data_marker = '"data":{'
      data_start_index = html_str.index(data_marker)
      return objs if data_start_index.nil? # No more data blocks in the page source

      data_closure_index = find_graphql_data_closure_index(html_str, data_start_index)
      return objs if data_closure_index.nil?

      graphql_data_str = html_str[data_start_index...data_closure_index].delete_prefix('"data":')
      objs + [graphql_data_str] + find_graphql_data_strings(html_str[data_closure_index..])
    end

    def find_graphql_data_closure_index(html_str, start_index)
      ind = start_index + 8 # length of data marker. Begin search right after open brace
      nil if ind > html_str.length

      brace_stack = 1
      loop do  # search for brace characters in substring instead of iterating through each char
        if html_str[ind] == "{"
          brace_stack += 1
          # puts "Brace open: #{brace_stack}"
        elsif html_str[ind] == "}"
          brace_stack -= 1
          # puts "Brace close: #{brace_stack}"
        end

        # brace_stack += 1 if str[ind] == '{'
        # brace_stack -= 1 if str[ind] == '{'
        ind += 1
        break if brace_stack.zero?
      end
      ind
    end

  private

    # Logs in to Facebook (if not already logged in)
    def login
      return unless page.title.downcase.include?("facebook - log in")  # We should only see this page title if we aren't logged in
      raise MissingCredentialsError if ENV["FACEBOOK_EMAIL"].nil? || ENV["FACEBOOK_PASSWORD"].nil?

      visit("/")  # Visit the Facebook home page
      fill_in("email", with: ENV["FACEBOOK_EMAIL"])
      fill_in("pass", with: ENV["FACEBOOK_PASSWORD"])
      click_button("Log In")
      sleep 3
    end

    # Ensures that a valid Facebook url has bene provided, and that it points to an available post
    # If either of those two conditions are false, raises an exception
    def validate_and_load_page(url)
      facebook_url_pattern = /https:\/\/www.facebook.com\//
      visit "https://www.facebook.com" if !facebook_url_pattern.match?(current_url)
      login
      raise Forki::InvalidUrlError unless facebook_url_pattern.match?(url)


      visit url
      retry_count = 0
      while retry_count < 5
        begin
          raise Forki::ContentUnavailableError if all("span").any? { |span| span.text == "This Content Isn't Available Right Now" }
          break
        rescue Selenium::WebDriver::Error::StaleElementReferenceError => error
          print({ error: "Error scraping spans", url: url, count: retry_count }.to_json)
          retry_count += 1
          raise error if retry_count > 4
          refresh
          # Give it a second (well, five)
          sleep(5)
        end
      end
    end

    # Extracts an integer out of a string describing a number
    # e.g. "4K Comments" returns 4000
    # e.g. "131 Shares" returns 131
    def extract_int_from_num_element(element)
      return unless element
      if element.class != String  # if an html element was passed in
        element = element.text(:all)
      end
      num_pattern = /[0-9KM ,.]+/
      interaction_num_text = num_pattern.match(element)[0]

      if interaction_num_text.include?(".")  # e.g. "2.2K"
        interaction_num_text.to_i + interaction_num_text[-2].to_i * 100
      elsif interaction_num_text.include?("K") # e.g. "13K"
        interaction_num_text.to_i * 1000
      elsif interaction_num_text.include?("M") # e.g. "13M"
        interaction_num_text.to_i * 1_000_000
      else  # e.g. "15,443"
        interaction_num_text.delete([",", " "]).to_i
      end
    end
  end
end

require_relative "post_scraper"
require_relative "user_scraper"
