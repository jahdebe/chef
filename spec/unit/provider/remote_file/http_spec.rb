#
# Author:: Lamont Granquist (<lamont@opscode.com>)
# Copyright:: Copyright (c) 2013 Lamont Granquist
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'spec_helper'

describe Chef::Provider::RemoteFile::HTTP do

  let(:uri) { URI.parse("http://opscode.com/seattle.txt") }

  describe "when contructing the object" do
    before do
      @new_resource = mock('Chef::Resource::RemoteFile (new_resource)')
      @current_resource = mock('Chef::Resource::RemoteFile (current_resource)')
      @new_resource.stub!(:headers).and_return({})
    end

    describe "when the current resource has no source" do
      before do
        @current_resource.should_receive(:source).and_return(nil)
      end

      it "stores the uri it is passed" do
        fetcher = Chef::Provider::RemoteFile::HTTP.new(uri, @new_resource, @current_resource)
        fetcher.uri.should == uri
      end

      it "stores any headers it is passed" do
        headers = { "foo" => "foo", "bar" => "bar", "baz" => "baz" }
        @new_resource.stub!(:headers).and_return(headers)
        fetcher = Chef::Provider::RemoteFile::HTTP.new(uri, @new_resource, @current_resource)
        fetcher.headers.should == headers
      end

    end

    describe "when the current resource has a source" do

      it "stores the last_modified string in the headers when we are using last_modified headers and the uri matches the cache" do
        @current_resource.stub!(:source).and_return(["http://opscode.com/seattle.txt"])
        @new_resource.should_receive(:use_last_modified).and_return(true)
        @current_resource.stub!(:last_modified).and_return(Time.new)
        @current_resource.stub!(:etag).and_return(nil)
        Chef::Provider::RemoteFile::Util.should_receive(:uri_matches_string?).with(uri, @current_resource.source[0]).and_return(true)
        fetcher = Chef::Provider::RemoteFile::HTTP.new(uri, @new_resource, @current_resource)
        fetcher.headers['if-modified-since'].should == @current_resource.last_modified.strftime("%a, %d %b %Y %H:%M:%S %Z")
        fetcher.headers.should_not have_key('if-none-match')
      end

      it "stores the etag string in the headers when we are using etag headers and the uri matches the cache" do
        @current_resource.stub!(:source).and_return(["http://opscode.com/seattle.txt"])
        @new_resource.should_receive(:use_etag).and_return(true)
        @new_resource.should_receive(:use_last_modified).and_return(false)
        @current_resource.stub!(:last_modified).and_return(Time.new)
        @current_resource.stub!(:etag).and_return("a_unique_identifier")
        Chef::Provider::RemoteFile::Util.should_receive(:uri_matches_string?).with(uri, @current_resource.source[0]).and_return(true)
        fetcher = Chef::Provider::RemoteFile::HTTP.new(uri, @new_resource, @current_resource)
        fetcher.headers['if-none-match'].should == "\"#{@current_resource.etag}\""
        fetcher.headers.should_not have_key('if-modified-since')
      end

    end

    describe "when use_last_modified is disabled in the new_resource" do

      it "stores nil for the last_modified date" do
        @current_resource.stub!(:source).and_return(["http://opscode.com/seattle.txt"])
        @new_resource.should_receive(:use_last_modified).and_return(false)
        @current_resource.stub!(:last_modified).and_return(Time.new)
        @current_resource.stub!(:etag).and_return(nil)
        Chef::Provider::RemoteFile::Util.should_receive(:uri_matches_string?).with(uri, @current_resource.source[0]).and_return(true)
        fetcher = Chef::Provider::RemoteFile::HTTP.new(uri, @new_resource, @current_resource)
        fetcher.headers.should_not have_key('if-modified-since')
        fetcher.headers.should_not have_key('if-none-match')
      end
    end

  end

  describe "when fetching the uri" do
    let(:fetcher) do
      Chef::Provider::RemoteFile::Util.should_receive(:uri_matches_string?).with(uri, @current_resource.source[0]).and_return(true)
      Chef::Provider::RemoteFile::HTTP.new(uri, @new_resource, @current_resource)
    end

    before do
      @new_resource = mock('Chef::Resource::RemoteFile (new_resource)')
      @current_resource = mock('Chef::Resource::RemoteFile (current_resource)')
      @new_resource.should_receive(:headers).and_return({})
      @current_resource.stub!(:source).and_return(["http://opscode.com/seattle.txt"])
      @new_resource.should_receive(:use_last_modified).and_return(false)
      @current_resource.stub!(:last_modified).and_return(Time.new)
      @current_resource.stub!(:etag).and_return(nil)
      @rest = mock(Chef::REST)
      Chef::REST.should_receive(:new).and_return(@rest)
      @tempfile = mock(Tempfile)
      @rest.stub!(:streaming_request).and_return(@tempfile)
      @rest.stub!(:last_response).and_return({})
      @result = mock(Chef::Provider::RemoteFile::Result)
      Chef::Provider::RemoteFile::Result.stub!(:new).and_return(@result)
    end

    it "should return a result" do
      Chef::REST.should_receive(:new).and_return(@rest)
      Chef::Provider::RemoteFile::Result.stub!(:new).and_return(@result)
      fetcher.fetch.should == @result
    end

    it "should propagate non-304 exceptions to the caller" do
      Chef::REST.should_receive(:new).and_return(@rest)
      r = Net::HTTPBadRequest.new("one", "two", "three")
      e = Net::HTTPServerException.new("fake exception", r)
      Chef::Provider::RemoteFile::Result.stub!(:new).and_return(@result)
      @rest.stub!(:streaming_request).and_raise(e)
      lambda { fetcher.fetch }.should raise_error(Net::HTTPServerException)
    end

    it "should return HTTPRetriableError when Chef::REST returns a 301" do
      Chef::REST.should_receive(:new).and_return(@rest)
      r = Net::HTTPMovedPermanently.new("one", "two", "three")
      e = Net::HTTPRetriableError.new("301", r)
      Chef::Provider::RemoteFile::Result.stub!(:new).and_return(@result)
      @rest.stub!(:streaming_request).and_raise(e)
      lambda { fetcher.fetch }.should raise_error(Net::HTTPRetriableError)
    end

    it "should return a nil tempfile for a 304 HTTPNotModifed" do
      Chef::REST.should_receive(:new).and_return(@rest)
      r = Net::HTTPNotModified.new("one", "two", "three")
      e = Net::HTTPRetriableError.new("304", r)
      @rest.stub!(:streaming_request).and_raise(e)
      Chef::Provider::RemoteFile::Result.should_receive(:new).with(nil, nil, nil).and_return(@result)
      fetcher.fetch.should == @result
    end

    it "should disable gzip compression in the client for *gz files" do
      uri = URI.parse("http://opscode.com/tarball.tgz")
      Chef::REST.should_not_receive(:new)
      #Chef::REST.should_receive(:new).with(uri, nil, nil, {:disable_gzip => true }).and_return(@rest)
      Chef::Provider::RemoteFile::Result.stub!(:new).and_return(@result)
      fetcher.fetch.should == @result
    end
  end

end

