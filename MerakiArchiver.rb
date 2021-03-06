#!/usr/bin/ruby
# available input arguments:
# 	--orgID <id>: ID of the Meraki Dashboard organization where the cameras are
# 	--apiKeyFile <file>: single-line file containing the API key for Meraki dashboard
# 	--cameraKeysFile <file>: file containing keys for cameras
# 	--newListFile <file>: file obtained from the Camera > Cameras page
# 	--videoOutputDir <directory>: directory where video files will be stored
# 	--maxVideoLength <seconds>: maximum length of .mp4 video file
# 	--videoOverlap <seconds>: how early the next ffmpeg will be started before the end of the previous
# 	--maxVideosPerCamera <n>: maximum number of videos kept per camera


# NOTES:
# 	- cameras are only reached locally, not through cloud streaming
# 	- all cameras need to be in the same organization
#   - the camera will preferrably be connected via cable, not via WiFi, although it should not matter


require 'pp'
require 'httparty'
require 'json'
require 'logger'
require 'csv'
require 'date'
require 'thread'
require 'sys-proctable'		# this gem allows getting similar output as ps, but it is platform-agnostic

require_relative 'Camera'
require_relative 'FFmpegWorker'
require_relative 'MultiLogger'

SUPPORT_720P = ["MV21", "MV71"]		# also, these are the gen 1 models
SUPPORT_1080P = ["MV22", "MV72", "MV12"]		# these are the gen 2 models
MANPAGE = "docs/manpage.txt"		# manual page for this
ARG_LIST = ["--orgID", "--apiKeyFile", "--cameraKeysFile", "--newListFile", "--videoOutputDir",
						"--maxVideoLength", "--videoOverlap", "--maxVideosPerCamera"]	# list of available arguments


BEGIN {
  puts "MerakiArchiver is starting..."
	if ARGV.size < 1
		puts "Not enough input arguments, need at least --orgID <id>"
		exit
  end
}

END {
  puts "\n\nMerakiArchiver is ending..."
	# `pkill ffmpeg`		# this kind of cleanup is a little dangerous
}

def readInputArguments(args)
	# input will be ARGV, return hash with input arguments
	outHash = {}
	args.each_index { |i|
		if (args[i][0,2] != "--")
			next
		else
			outHash[args[i]] = args[i+1]
		end
	}

	return outHash
end

def readSingleLineFile(file)
	if !File.exist?(file) then return false end		# return false if file cannot be found
	File.read(file)
end

def readnewListFile(file)
	# find "flux.actions.cameras.video_channels.reset" in the file given
	# return the JSON array flux.actions.cameras.video_channels.reset
	if !File.exist?(file) then return false end		# return false if file cannot be found

	tmpStr = File.read(file)
	matchStr = "flux.actions.cameras.video_channels.reset("
	matchStrSize = matchStr.length

	# grab only the JSON portion of the string
	pos1 = tmpStr.index(matchStr)
	pos2 = tmpStr.index(';', pos1)
	outStr = tmpStr[pos1+matchStrSize, pos2-pos1-1-matchStrSize]

	return JSON.parse(outStr, symbolize_names: true)	# convert response body to JSON for easier parsing
end

def getCamerasInOrg(orgID, header)
  # run API call to retrieve organization inventory
	# return array of hashes containing info about the cameras in the organization
  url = "https://api.meraki.com/api/v0/organizations/#{orgID.to_s}/inventory"
  regexpExpr = /MV\d{1,3}[Ww]{0,1}/		# this should match any camera model
  output = Array.new

  jResponse = runAPICall(url, header)
	(0...jResponse.length).each do |i|
    if (jResponse[i][:model].match(regexpExpr))  # MVs do not have 3 numbers in their model yet
      # puts jResponse[i][:model]
      output << jResponse[i]
    end
  end

  return output
end

def getDevice(cameraObj, header)
	# run API call to get more information about the device
	# return hash with device information
	unless cameraObj.class == Camera
		puts "getDevice got a #{cameraObj.class} object, expecting Camera"
		return nil
	end

	url = "https://api.meraki.com/api/v0/networks/#{cameraObj.networkId}/devices/#{cameraObj.serial}"
	runAPICall(url, header)
end

def getCameraLink(cameraObj, header)
	# run the videoLink API call for cameras, return string with video link
	unless cameraObj.class == Camera
		puts "getCameraLink got a #{cameraObj.class} object, expecting Camera"
		return nil
	end

	url = "https://api.meraki.com/api/v0/networks/#{cameraObj.networkId}/cameras/#{cameraObj.serial}/videoLink"
	runAPICall(url, header)[:url]
end

def runAPICall(url, header)
	# run API call using url and header provided
	# return false if the call failed, nil if nothing was returned or hash with information
	response = HTTParty.get(url, :headers => header)
	if (response.code != 200) then return false end		# for a successful API call, we expect to receive an HTTP code 200

	return JSON.parse(response.body, symbolize_names: true)	# convert response body to JSON for easier parsing
end

def checkCameraReachable(cameraObj, logger)
	# check if camera is reachable on the LAN
	# mark the camera as not reachable locally only if TCP:443 fails
	unless cameraObj.class == Camera
		logger.write("checkCameraReachable got a #{cameraObj.class} object, expecting Camera", "debug", false)
		return nil
	end


	logger.write("Attempting to reach #{cameraObj.name} (#{cameraObj.serial}) at #{cameraObj.lanIp} ...", "info", true)
	# `ping #{cameraObj.lanIp} -c 2`
	# unless $?.success?
	# 	puts "\tFailed PING"
	# 	cameraObj.isReachable = false
	# end

	curlCmd = "curl --connect-timeout 2 --silent #{cameraObj.lanIp}:443"
	logger.write("curlCmd: #{curlCmd}", "debug", true)
	`#{curlCmd}`		# this should return an empty reply
	logger.write("#{$?.inspect}", "debug", false)

	if $?.exitstatus == 52
		logger.write("Success TCP:443, camera reachable", "info", true)
		cameraObj.isReachable = true
		return true
	else
		logger.write("Failed TCP:443, camera unreachable", "info", true)
		cameraObj.isReachable = false
		return false
	end
end

def readCameraKeys(file)
	tmpHash = {}
	if !File.exist?(file) then return false end		# return false if file cannot be found

	CSV.foreach(file) do |row|
  	if (row[0][0] != '#')		# ignore lines starting with '#'
			tmpHash[row[0]] = row[1]
		end
	end
	return tmpHash
end

def writeCameraKeys(file, inValues)
	unless inValues.class == Hash
		multiLogger.write("writeCameraKeys received unexpected object #{inValues.class}", "debug", true)
		return false
	end

	# TODO: check whether file is opened successfully
	File.open(file, "w") { |f|
		f << "# serial,key"		# header
		(0...inValues.keys.size).each do |i|
			f << "\n"
			f << inValues.keys[i] << "," << inValues[inValues.keys[i]]
		end
	}
end

def buildM3U8Url(cameraObj)
	# build the URL for the .m3u8 playlist file
	tmpStr = "https://"
	tmpStr += cameraObj.lanIp.gsub('.', '-')
	tmpStr += "."
	tmpStr += cameraObj.mac.gsub(':', '')
	tmpStr += ".devices.meraki.direct/hls/"

	if (SUPPORT_1080P.index(cameraObj.model[0,4]) != nil)
		# camera model is gen 2
		tmpStr += "high/high"
	end

	tmpStr += cameraObj.cameraKey + ".m3u8"
end




# create Logger object and start logging things
baseLogFileDir = "./"	# directory where log files created by Logger will be stored
loggerObj = Logger.new(baseLogFileDir + "MerakiArchiver.log", 10, 1*1024*1024)
loggerObj.level = Logger::DEBUG
multiLogger = MultiLogger.new(loggerObj)
multiLogger.write("Logger has started", "info", true)


# read input arguments, store them to the appropriate variables and do a couple of checks
multiLogger.write("Reading input arguments ...", "info", true)
argsHash = readInputArguments(ARGV)
multiLogger.write("#{argsHash.inspect}", "debug", false)

# check if any incorrect arguments are passed
if !(argsHash.keys - ARG_LIST).empty?
	multiLogger.write("Incorrect arguments, #{(argsHash.keys - ARG_LIST).to_s}", "error", true)
	exit
end

orgID = argsHash["--orgID"]
merakiAPIKey = readSingleLineFile(argsHash["--apiKeyFile"])   # key for API calls
videoOutputDir = argsHash["--videoOutputDir"]
maxVideoLength = argsHash["--maxVideoLength"].to_i
videoOverlap = argsHash["--videoOverlap"].to_i
cameraKeysFile = argsHash["--cameraKeysFile"]
newListFile = nil
maxVideosPerCamera = 0
if argsHash.has_key?("--maxVideosPerCamera")
	maxVideosPerCamera = argsHash["--maxVideosPerCamera"].to_i
end

if argsHash.has_key?("--newListFile") && argsHash.has_key?("--cameraKeysFile")
	multiLogger.write("Do not use both --newListFile and --cameraKeysFile", "error", true)
	exit
end


# if a cameraKeysFile is given, ignore the newListFile
unless cameraKeysFile
	cameraKeysFile = "cameraKeys"		# assign default value
	newListFile = argsHash["--newListFile"]
end

baseBody = {}
baseHeaders = {"Content-Type" => "application/json",
            "X-Cisco-Meraki-API-Key" => merakiAPIKey}

unless merakiAPIKey		# API key must be provided, it is nil if not provided
	multiLogger.write("Could not read API key", "fatal", true)
	exit
end
puts "API Key: #{'*' * 35}" + merakiAPIKey[-6,5]		# show a portion of the API key
multiLogger.write("API Key: #{'*' * 35}#{merakiAPIKey[-6,5]}", "debug", false)	# hide it




# get the list of all the cameras in this organization and store information about them
multiLogger.write("Getting list of cameras in the organization ...", "info", true)
tmpList = getCamerasInOrg(orgID, baseHeaders)
if tmpList == nil
	multiLogger.write("Could not retrieve cameras in organization inventory", "fatal", true)
	exit
elsif tmpList.empty?
	multiLogger.write("Organization inventory does not have cameras", "fatal", true)
	exit
end

# put the cameras in a list of Camera objects
multiLogger.write("Found #{tmpList.size} cameras in organization #{orgID}", "info", true)
cameraList = Array.new
(0...tmpList.size).each do |i|
	cameraList << Camera.new(tmpList[i][:mac], tmpList[i][:serial], tmpList[i][:networkId], tmpList[i][:model], tmpList[i][:claimedAt], tmpList[i][:publicIp], tmpList[i][:name])
	multiLogger.write("#{cameraList[i].inspect}", "debug", false)
end



# do camera API calls to get more information, like their LAN IP and videoLink
multiLogger.write("Collecting more information about the cameras ...", "info", true)
(0...cameraList.size).each do |i|
	output = getDevice(cameraList[i], baseHeaders)
	cameraList[i].lat = output[:lat]
	cameraList[i].lng = output[:lng]
	cameraList[i].address = output[:address]
	cameraList[i].notes = output[:notes]
	cameraList[i].lanIp = output[:lanIp]
	cameraList[i].tags = output[:tags]

	cameraList[i].apiVideoLink = getCameraLink(cameraList[i], baseHeaders)
	cameraList[i].node_id = cameraList[i].apiVideoLink[/\d{5,}/]	# node_id is 5+ digits

	multiLogger.write("#{cameraList[i].inspect}", "debug", false)
end
puts "\n\n"



# check if the cameras are reachable locally
# attempt to ping them and open a TCP:443 connection to their LAN IP
multiLogger.write("Checking if cameras are reachable ...", "info", true)
camReachable = 0
camUnreachable = 0
(0...cameraList.size).each do |i|
	# do it like this so we can show how many cameras are reachable/unreachable
	if checkCameraReachable(cameraList[i], multiLogger) then camReachable += 1 else camUnreachable += 1 end
	puts "\n"
end

multiLogger.write("Cameras reachable locally: #{camReachable}", "info", true)
multiLogger.write("Cameras not reachable locally: #{camUnreachable}", "info", true)

if camReachable == 0	# if no cameras are reachable locally, exit
	multiLogger.write("I cannot reach any cameras locally :(, exiting...", "fatal", true)
	exit
end
puts "\n\n"



if newListFile != nil
	# process the new_list file to derive cameraKeys
	multiLogger.write("Processing new_list file ...", "info", true)
	video_channels = readnewListFile(newListFile)

	# assign cameraKey to each Camera object, they are the value of m3u8_filename key
	if video_channels
		wKeys = {}		# makes it very easy to pass it to writeCameraKeys

		(0...cameraList.size).each do |i|
			(0...video_channels.size).each do |j|
				if video_channels[j][:node_id] == cameraList[i].node_id
					wKeys[cameraList[i].serial] = video_channels[j][:m3u8_filename]
					multiLogger.write("#{cameraList[i].inspect}", "debug", false)
					next
				end
			end
		end

		# write the values obtained to the cameraKeys file
		writeCameraKeys(cameraKeysFile, wKeys)
	else
		multiLogger.write("Could not find new_list file #{newListFile}", "error", true)
	end
end
puts "\n\n"



# start building the m3u8 url, cameras that do 1080p streams, will have "high" keywords
# https://<camera-IP>.<cameramac>.devices.meraki.direct/hls/<high>/<high><cameraKey>.m3u8
# read <cameraKey> from the file of cameraKeys collected previously
multiLogger.write("Reading cameraKeys file: #{cameraKeysFile}", "info", true)
cameraKeyList = readCameraKeys(cameraKeysFile)
cameraList.reject!{|x| !cameraKeyList.keys.include?(x.serial)}	# remove cameras we do not have a cameraKey for
cameraList.each {|x| x.cameraKey = cameraKeyList[x.serial]}		# assign cameraKeys
unless cameraKeyList
	multiLogger.write("Could not read cameraKeys, exiting ...", "fatal", true)
	exit
end



# build the URL and set it to the appropriate Camera object
(0...cameraList.size).each do |i|
	cameraList[i].m3u8Url = buildM3U8Url(cameraList[i])
	multiLogger.write("#{cameraList[i].serial} - #{cameraList[i].m3u8Url}", "debug", true)
end
puts "\n\n"



# create directories to store video files
multiLogger.write("Creating directories to store video files ...", "info", true)
unless (Dir.exist?(videoOutputDir))
	Dir.mkdir(videoOutputDir)
end

(0...cameraList.size).each do |i|
	unless cameraList[i].isReachable
		next
	end

	# call the directories something like <camera-name>_<camera_serial>
	# remove any - or spaces from the directory name
	tmpDir = videoOutputDir + "#{cameraList[i].name.gsub(' ', '_')}_#{cameraList[i].serial.gsub('-', '')}"
	cameraList[i].videoDir = tmpDir
	if (Dir.exist?(tmpDir))
		multiLogger.write("Directory already exists, #{tmpDir}", "info", true)
		next
	else
		multiLogger.write("Creating directory #{tmpDir}", "info", true)
		Dir.mkdir(tmpDir)
	end
end
puts "\n\n"



# run the ffmpeg workers in separate threads
# if the camera is reachable, run the thread
ffmpegWorkerArray = Array.new
threadArray = Array.new
(0...cameraList.size).each do |i|

	if (cameraList[i].isReachable)
		ffmpegTmp = FFmpegWorker.new(cameraList[i], multiLogger)
		ffmpegTmp.maxVideoLength = maxVideoLength
		ffmpegTmp.videoOverlap = videoOverlap
		ffmpegTmp.maxVideosPerCamera = maxVideosPerCamera

		ffmpegWorkerArray << ffmpegTmp

		threadArray << Thread.new(i) do |i|
			ffmpegWorkerArray[i].run
		end
	end
end

multiLogger.write("Starting #{threadArray.size} threads...", "info", true)
threadArray.each {|t| t.join}

multiLogger.close
