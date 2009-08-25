/*    
 *    Copyright (c) 2009 Open Video Ads - Option 3 Ventures Limited
 *
 *    This file is part of the Open Video Ads Flowplayer Open Ad Streamer.
 *
 *    The Open Ad Streamer is free software: you can redistribute it 
 *    and/or modify it under the terms of the GNU General Public License 
 *    as published by the Free Software Foundation, either version 3 of 
 *    the License, or (at your option) any later version.
 *
 *    The Open Ad Streamer is distributed in the hope that it will be 
 *    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU General Public License for more details.
 *
 *    You should have received a copy of the GNU General Public License
 *    along with the framework.  If not, see <http://www.gnu.org/licenses/>.
 */
package org.openvideoads.plugin.flowplayer.streamer {
	import org.openvideoads.base.Debuggable;
	import org.openvideoads.util.DisplayProperties;
	import org.openvideoads.util.StringUtils;
	import org.openvideoads.vast.VASTController;
	import org.openvideoads.vast.config.Config;
	import org.openvideoads.vast.events.AdNoticeDisplayEvent;
	import org.openvideoads.vast.events.CompanionAdDisplayEvent;
	import org.openvideoads.vast.events.LinearAdDisplayEvent;
	import org.openvideoads.vast.events.NonLinearSchedulingEvent;
	import org.openvideoads.vast.events.OverlayAdDisplayEvent;
	import org.openvideoads.vast.events.SeekerBarEvent;
	import org.openvideoads.vast.events.StreamSchedulingEvent;
	import org.openvideoads.vast.events.TemplateEvent;
	import org.openvideoads.vast.events.TrackingPointEvent;
	import org.openvideoads.vast.model.CompanionAd;
	import org.openvideoads.vast.playlist.Playlist;
	import org.openvideoads.vast.schedule.ads.AdSlot;
	import org.openvideoads.vast.tracking.TimeEvent;
	import org.openvideoads.vast.tracking.TrackingPoint;
	import org.openvideoads.vast.tracking.TrackingTable;
	
	import flash.external.ExternalInterface;
	import flash.display.Sprite;
	
	import org.flowplayer.controls.Controls;
	import org.flowplayer.model.Clip;
	import org.flowplayer.model.ClipEvent;
	import org.flowplayer.model.ClipType;
	import org.flowplayer.model.Cuepoint;
	import org.flowplayer.model.PlayerEvent;
	import org.flowplayer.model.Plugin;
	import org.flowplayer.model.PluginModel;
	import org.flowplayer.util.PropertyBinder;
	import org.flowplayer.view.AbstractSprite;
	import org.flowplayer.view.Flowplayer;
	
	/**
	 * @author Paul Schulz
	 */
	public class OpenAdStreamer extends AbstractSprite implements Plugin {
		protected var _player:Flowplayer;
		protected var _model:PluginModel;
       	protected var _vastController:VASTController;
		protected var _wasZeroVolume:Boolean = false;
		protected var _activeStreamIndex:int = -1;
        protected var _playlist:Playlist;
        protected var _previousDivContent:Array = new Array();
        protected var _clipList:Array = new Array();
        protected var _replayClipList:Array = new Array();
        protected var _firstClipScheduled:Boolean = false;
        protected var _activeShowClip:Clip = null;
        protected var _playedOnce:Boolean = false;
        
        protected static var STREAMING_PROVIDERS:Object = {
           rtmp: "flowplayer.rtmp-3.1.3-dev.swf"
        };

		public function OpenAdStreamer() {
		}

		public function onConfig(model:PluginModel):void {
			_model = model;
		}
				
		public function onLoad(player:Flowplayer):void {
			_player = player;
			//_player.logging("error");
            initialiseVASTFramework();
		}
		
		public function getDefaultConfig():Object {
			return { top: 0, left: 0, width: "100%", height: "100%" };
		}

		override protected function onResize():void {
			super.onResize();
			if(_vastController != null) {
				_vastController.resizeOverlays(new DisplayProperties(this, width, height, 25, 640, 360));
			}
		}
		        				
		protected function initialiseVASTFramework():void {
			// Load up the config and configure the debugger
			_vastController = new VASTController();
			_vastController.setTimeBaseline(VASTController.RELATIVE_TO_CLIP);
			_vastController.trackStreamSlices = false;
			_vastController.startStreamSafetyMargin = 300; // needed because cuepoints at 0 for FLVs don't fire
			_vastController.initialise((new PropertyBinder(new Config(), null).copyProperties(_model.config) as Config));
			doLog("Flowplayer Open Video Ad Streamer constructed - build 0.1.1.1", Debuggable.DEBUG_ALL);

            // Before we do anything, load the providers if any have been specified
			loadUserSpecifiedProviders();
            
			// preserve the playlist if one has been specified - there is always 1 clip in the flowplayer playlist
			// even if no clips have been specified in the config - if there isn't a URL in the first clip, then
			// it's empty in the config - this is a bit of a hack - is there a better way to determine this?
			
			if(_player.playlist.clips[0].url != null) {
				_clipList = _player.playlist.clips;
				_activeShowClip = _clipList[_clipList.length - 1];
				doLog("Preserving the existing playlist - " + _player.playlist.toString(), Debuggable.DEBUG_SEGMENT_FORMATION);
			}
			
			// Setup the player tracking events
			_player.onFullscreen(onFullScreen);
			_player.onFullscreenExit(onFullScreenExit);
			_player.onMute(onMuteEvent);
			_player.onUnmute(onUnmuteEvent);
			_player.onVolume(onProcessVolumeEvent);  

            // Setup the critical listeners for the template loading process
            _vastController.addEventListener(TemplateEvent.LOADED, onTemplateLoaded);
            _vastController.addEventListener(TemplateEvent.LOAD_FAILED, onTemplateLoadError);

            // Setup the linear ad listeners
            _vastController.addEventListener(LinearAdDisplayEvent.STARTED, onLinearAdStarted);
            _vastController.addEventListener(LinearAdDisplayEvent.COMPLETE, onLinearAdComplete); 
            _vastController.addEventListener(LinearAdDisplayEvent.CLICK_THROUGH, onLinearAdClickThrough);           
           
           // Setup the companion display listeners
            _vastController.addEventListener(CompanionAdDisplayEvent.DISPLAY, onDisplayCompanionAd);
            _vastController.addEventListener(CompanionAdDisplayEvent.HIDE, onHideCompanionAd);

            // Decide how to handle overlay displays - if through the framework, turn it on, otherwise register the event callbacks
            _vastController.enableNonLinearAdDisplay(new DisplayProperties(this, 640, 360, 25));
            _vastController.addEventListener(OverlayAdDisplayEvent.DISPLAY, onDisplayOverlay);
            _vastController.addEventListener(OverlayAdDisplayEvent.HIDE, onHideOverlay);
            _vastController.addEventListener(OverlayAdDisplayEvent.DISPLAY_NON_OVERLAY, onDisplayNonOverlay);
            _vastController.addEventListener(OverlayAdDisplayEvent.HIDE_NON_OVERLAY, onHideNonOverlay);
            _vastController.addEventListener(OverlayAdDisplayEvent.CLICKED, onOverlayClicked);
            _vastController.addEventListener(AdNoticeDisplayEvent.DISPLAY, onDisplayNotice);
            _vastController.addEventListener(AdNoticeDisplayEvent.HIDE, onHideNotice);
          
            // Setup the hander for tracking point set events
            _vastController.addEventListener(TrackingPointEvent.SET, onSetTrackingPoint);
            _vastController.addEventListener(TrackingPointEvent.FIRED, onTrackingPointFired);
            
            // Setup the hander for display events on the seeker bar
            _vastController.addEventListener(SeekerBarEvent.TOGGLE, onToggleSeekerBar);
            
            // Ok, let's load up the VAST data from our Ad Server - when the stream sequence is constructed, register for callbacks
            _vastController.addEventListener(StreamSchedulingEvent.SCHEDULE, onStreamSchedule);
            _vastController.addEventListener(NonLinearSchedulingEvent.SCHEDULE, onNonLinearSchedule);
            _vastController.load();	
		}
		
		protected function loadUserSpecifiedProviders():void {
			if(_vastController.hasProvider("rtmp")) {
				ensureProviderPluginLoaded("rtmp", "rtmp");
			}
		}
		
		protected function ensureProviderPluginLoaded(providerName:String, providerPluginName:String):void {
			if(_player.pluginRegistry.getPlugin(providerName) == null) {
				var providerUrl:String = 
				          (_vastController.hasProvider(providerPluginName)) 
				                ? _vastController.getProviderUrl(providerPluginName) 
				                : STREAMING_PROVIDERS[providerPluginName];
			   if(providerUrl != null) {
			   	    doLog("Dynamically loading provider plugin " + providerName + " using " + providerUrl, Debuggable.DEBUG_CONFIG);
					_player.loadPlugin(providerName, providerUrl, onProviderLoaded);		   	
			   }
			   else doLog("Could not load provider " + providerName + " - no load information found");
			}
		}
		
		protected function onProviderLoaded(pluginModel:PluginModel):void {
			if(pluginModel != null) {
				doLog("Provider plugin " + pluginModel.name + " successfully loaded.", Debuggable.DEBUG_CONFIG);
				if(pluginModel.name == "rtmp") {
					ensureProviderPluginLoaded("rtmpInstream", "rtmp");
				}
			}
		}
		
		// Stream scheduling callbacks
		
		protected function onStreamSchedule(event:StreamSchedulingEvent):void {				
			doLogAndTrace("NOTIFICATION: Scheduling stream '" + event.stream.id + "' at index " + event.scheduleIndex, event, Debuggable.DEBUG_SEGMENT_FORMATION);

			// Add in the new clip details based on the stream that is to play
			var clip:ScheduledClip = new ScheduledClip();
			new PropertyBinder(clip, "customProperties").copyProperties(_player.playlist.commonClip) as Clip;
			clip.type = ClipType.fromMimeType(event.stream.mimeType); 
			clip.autoPlay = _vastController.config.playContiguously;
			clip.start = event.stream.getStartTimeAsSeconds();
			clip.duration = event.stream.getDurationAsInt();
			clip.originalDuration = event.stream.getOriginalDurationAsInt();
            if(event.stream.isRTMP()) {
				clip.url = event.stream.streamName;  
				clip.setCustomProperty("netConnectionUrl", event.stream.baseURL);
				clip.setCustomProperty("metaData", event.stream.metaData);
				clip.provider = "rtmp"          	
            }
            else {
				clip.url = event.stream.url;
				clip.provider = "http"; 
            }
			
			if(event.stream is AdSlot) {
				var adSlot:AdSlot = event.stream as AdSlot;
			}
			else {
				_activeShowClip = clip;
			}

            // Setup the flowplayer cuepoints based on the tracking points defined for this stream 
            // (including companions attached to linear ads)
            
			var trackingTable:TrackingTable = event.stream.getTrackingTable();
			for(var i:int=0; i < trackingTable.length; i++) {
				var trackingPoint:TrackingPoint = trackingTable.pointAt(i);
				if(trackingPoint.isLinear()) {
		            clip.addCuepoint(new Cuepoint(trackingPoint.milliseconds, trackingPoint.label + ":" + event.scheduleIndex));
					doLog("Flowplayer CUEPOINT set at " + trackingPoint.milliseconds + " with label " + trackingPoint.label + ":" + event.scheduleIndex, Debuggable.DEBUG_CUEPOINT_FORMATION);
				}
			}

            clip.onCuepoint(processCuepoint);

            // Add the clip into the clip list
                        
            if(event.stream is AdSlot) {
            	if(adSlot.isMidRoll()) {
					// If it's a mid-roll, insert the clip as a child of the current show stream
            		if(_activeShowClip != null) {
	    	   			doLog("Adding mid-roll ad as child (running time " + clip.duration + ") " + clip.provider + " - " + clip.baseUrl + ", " + clip.url, Debuggable.DEBUG_SEGMENT_FORMATION);
    	                if(_activeShowClip is ScheduledClip) {
	    	                _activeShowClip.duration = (_activeShowClip as ScheduledClip).originalDuration;	                	
    	                }
    	                clip.position = event.stream.getStartTimeAsSeconds();    	 
						_activeShowClip.addChild(clip);
            		}
            		else doLog("Cannot insert mid-roll ad - there is no active show clip to insert it into", Debuggable.DEBUG_SEGMENT_FORMATION);
           			return;            		            			
            	}	
            }
            else if(event.stream.isSlicedStream() && (event.stream.getStartTimeAsSeconds() > 0)) {
            	// because we are using the Flowplayer in-stream API, we don't sequence parts of the original show stream
            	// as separate clips in the playlist - so ignore any subsequent streams in the sequence that are spliced
            	return;
            }
            
	        // It's not a mid-roll ad so add in the clip to the end of the clip list
    	    doLog("Adding clip " + clip.provider + " - " + clip.baseUrl + ", " + clip.url, Debuggable.DEBUG_SEGMENT_FORMATION);

            // If this is the first clip that we are adding, and we are to set auto-start to false, set it now
			if(_firstClipScheduled == false) {
				clip.autoPlay = _vastController.autoStart();
				_firstClipScheduled = true;	
			}
			           
        	_clipList.push(clip);
		}

		protected function onNonLinearSchedule(event:NonLinearSchedulingEvent):void {
			doLogAndTrace("NOTIFICATION: Scheduling non-linear ad '" + event.adSlot.id + "' against stream at index " + event.adSlot.associatedStreamIndex + " ad slot is " + event.adSlot.key, event, Debuggable.DEBUG_SEGMENT_FORMATION);

            // setup the flowplayer cuepoints for non-linear ads (including companions attached to non-linear ads)
			var trackingTable:TrackingTable = event.adSlot.getTrackingTable();
			for(var i:int=0; i < trackingTable.length; i++) {
				var trackingPoint:TrackingPoint = trackingTable.pointAt(i);
				if(trackingPoint.isNonLinear()) {
		            _clipList[event.adSlot.associatedStreamIndex].addCuepoint(new Cuepoint(trackingPoint.milliseconds, trackingPoint.label + ":" + event.adSlot.associatedStreamIndex)); //key
					doLog("Flowplayer CUEPOINT set at " + trackingPoint.milliseconds + " with label " + trackingPoint.label + ":" + event.adSlot.associatedStreamIndex, Debuggable.DEBUG_CUEPOINT_FORMATION);
				}
			}
		}			

		// Tracking Point event callbacks

		protected function onSetTrackingPoint(event:TrackingPointEvent):void {
			// Not using this callback as the flowplayer cuepoints must be set on the clip when the clip is added to the playlist (see onStreamSchedule)
			doLog("NOTIFICATION: Request received to set a tracking point (" + event.trackingPoint.label + ") at " + event.trackingPoint.milliseconds + " milliseconds", Debuggable.DEBUG_TRACKING_EVENTS);
		}

		private function setScrubber(turnOn:Boolean):void {
			var controlProps:org.flowplayer.model.DisplayProperties = _player.pluginRegistry.getPlugin("controls") as org.flowplayer.model.DisplayProperties;
			var controls:Controls = controlProps.getDisplayObject() as Controls;

			if(turnOn) {
				doLog("Turning the scrubber on", Debuggable.DEBUG_TRACKING_EVENTS);
				controls.enable({all: true, scrubber: true});		
			}	
			else {
				doLog("Turning the scrubber off", Debuggable.DEBUG_TRACKING_EVENTS);
				controls.enable({all: true, scrubber: false});		
			}
		}

		protected function onTrackingPointFired(event:TrackingPointEvent):void {
			doLog("NOTIFICATION: Request received that a tracking point was fired (" + event.trackingPoint.label + ") at " + event.trackingPoint.milliseconds + " milliseconds", Debuggable.DEBUG_TRACKING_EVENTS);
			/*			
				switch(event.eventType) {
					case TrackingPointEvent.LINEAR_AD_STARTED:
					case TrackingPointEvent.LINEAR_AD_COMPLETE:
				}
			*/
			_player.playlist.onFinish(
			        function(clipevent:ClipEvent):void {
			        	var currentClip:ScheduledClip = _player.currentClip as ScheduledClip;
			        	if(!_playedOnce && _vastController.playOnce && !currentClip.marked) {
			        		currentClip.marked = true;
			        		// Manage the playlist so that ads are not replayed
	 						if(_vastController.streamSequence.streamAt(_player.playlist.currentIndex) is AdSlot) {
	 							// don't add it to the replay list
	 							doLog("Discarding the current clip - it's an ad that has been played once", Debuggable.DEBUG_PLAYLIST);
	 						}
	 						else _replayClipList.push(_player.currentClip);
	 						
	 						if(_player.playlist.currentIndex == _player.playlist.length-1) {
	 							// we are at the last item to be played so reload the cliplist
	 							_clipList = _replayClipList
	 							_playedOnce = true;
	 							_replayClipList = new Array();
	 							if(_clipList.length > 0) _clipList[0].autoPlay = false; 
	 							_player.playlist.replaceClips2(_clipList);
	 							doLog("Playlist has been reset - total clips is now " + _clipList.length, Debuggable.DEBUG_PLAYLIST);
	 						}			        		
			        	}
			        }
			);
		}
 	
		protected function processCuepoint(clipevent:ClipEvent):void {
			var cuepoint:Cuepoint = clipevent.info as Cuepoint;
	    	var streamIndex:int = parseInt(cuepoint.callbackId.substr(3));
	        var eventCode:String = cuepoint.callbackId.substr(0,2);
			doLog("Cuepoint triggered " + clipevent.toString() + " - id: " + cuepoint.callbackId, Debuggable.DEBUG_CUEPOINT_EVENTS);
	        _vastController.processTimeEvent(streamIndex, new TimeEvent(clipevent.info.time, 0, eventCode));            	            
		}

		protected function processPopupVideoAdCuepoint(clipevent:ClipEvent):void {
			var cuepoint:Cuepoint = clipevent.info as Cuepoint;
	    	var streamIndex:int = parseInt(cuepoint.callbackId.substr(3));
	        var eventCode:String = cuepoint.callbackId.substr(0,2);
			doLog("Popup cuepoint triggered " + clipevent.toString() + " - id: " + cuepoint.callbackId, Debuggable.DEBUG_CUEPOINT_EVENTS);
	        _vastController.processPopupVideoAdTimeEvent(streamIndex, new TimeEvent(clipevent.info.time, 0, eventCode));            	            
		}
		
		// VAST data event callbacks
		
		protected function onTemplateLoaded(event:TemplateEvent):void {
			doLogAndTrace("NOTIFICATION: VAST data loaded - ", event.template, Debuggable.DEBUG_FATAL);
            _player.playlist.replaceClips2(_clipList);
            _model.dispatchOnLoad();
		}

		protected function onTemplateLoadError(event:TemplateEvent):void {
			doLog("NOTIFICATION: FAILURE loading VAST template - " + event.toString(), Debuggable.DEBUG_FATAL);
		}

        // Seekbar callbacks

		public function onToggleSeekerBar(event:SeekerBarEvent):void {
			if(_vastController.disableControls) {
 			    doLog("NOTIFICATION: Request received to change the control bar state to " + ((event.turnOff()) ? "BLOCKED" : "ON"), Debuggable.DEBUG_DISPLAY_EVENTS);
			}
			else doLog("NOTIFICATION: Ignoring request to change control bar state", Debuggable.DEBUG_DISPLAY_EVENTS);
		}

        // Linear Ad callbacks

		public function onLinearAdStarted(linearAdDisplayEvent:LinearAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received that linear ad has started", Debuggable.DEBUG_DISPLAY_EVENTS);
			if(_vastController.disableControls) setScrubber(false);
		}	

		public function onLinearAdComplete(linearAdDisplayEvent:LinearAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received that linear ad is complete", Debuggable.DEBUG_DISPLAY_EVENTS);
			if(_vastController.disableControls) setScrubber(true);
		}	

		public function onLinearAdClickThrough(linearAdDisplayEvent:LinearAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received that linear ad click through activated", Debuggable.DEBUG_DISPLAY_EVENTS);			
			if(_vastController.pauseOnClickThrough) _player.pause();
		}

        // Ad Notice callbacks

		public function onDisplayNotice(displayEvent:AdNoticeDisplayEvent):void {	
			doLog("NOTIFICATION: Event received to display ad notice", Debuggable.DEBUG_DISPLAY_EVENTS);
		}
				
		public function onHideNotice(displayEvent:AdNoticeDisplayEvent):void {	
			doLog("NOTIFICATION: Event received to hide ad notice", Debuggable.DEBUG_DISPLAY_EVENTS);
		}

        // Overlay callbacks
				
		public function onDisplayOverlay(displayEvent:OverlayAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received to display non-linear overlay ad", Debuggable.DEBUG_DISPLAY_EVENTS);
		}

		public function onOverlayClicked(displayEvent:OverlayAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received - overlay has been clicked!", Debuggable.DEBUG_DISPLAY_EVENTS);
			if(displayEvent.ad.hasAccompanyingVideoAd()) {
				var clip:ScheduledClip = new ScheduledClip();
				var overlayAdSlot:AdSlot = _vastController.adSchedule.getSlot(displayEvent.adSlotKey);
				
				clip.type = ClipType.fromMimeType(overlayAdSlot.mimeType);
				clip.autoPlay = _vastController.config.playContiguously;
				clip.start = 0;
				clip.originalDuration = overlayAdSlot.getAttachedLinearAdDurationAsInt();
				clip.duration = clip.originalDuration;

	            if(overlayAdSlot.isRTMP()) {
					clip.url = overlayAdSlot.streamName;
					clip.setCustomProperty("netConnectionUrl", overlayAdSlot.baseURL);
					clip.provider = "rtmp";          	
            	}
            	else {
					clip.url = overlayAdSlot.url;
					clip.provider = "http";
            	}

            	// Setup the flowplayer cuepoints based on the tracking points defined for this 
            	// linear ad (including companions attached to linear ads)

            	clip.onCuepoint(processPopupVideoAdCuepoint);
				var trackingTable:TrackingTable = overlayAdSlot.getTrackingTable();
				for(var i:int=0; i < trackingTable.length; i++) {
					var trackingPoint:TrackingPoint = trackingTable.pointAt(i);
					if(trackingPoint.isLinear()) {
			            clip.addCuepoint(new Cuepoint(trackingPoint.milliseconds, trackingPoint.label + ":" + displayEvent.adSlotKey));
						doLog("Flowplayer CUEPOINT set for attached linear ad at " + trackingPoint.milliseconds + " with label " + trackingPoint.label + ":" + displayEvent.adSlotKey, Debuggable.DEBUG_CUEPOINT_FORMATION);
					}
				}

				_player.playInstream(clip);
			}
			else _player.pause();
		}
		
		public function onHideOverlay(displayEvent:OverlayAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received to hide non-linear overlay ad", Debuggable.DEBUG_DISPLAY_EVENTS);
		}

		public function onDisplayNonOverlay(displayEvent:OverlayAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received to display non-linear non-overlay ad", Debuggable.DEBUG_DISPLAY_EVENTS);
		}
		
		public function onHideNonOverlay(displayEvent:OverlayAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received to hide non-linear non-overlay ad", Debuggable.DEBUG_DISPLAY_EVENTS);
		}

        // Companion Ad Display Events
        
        public function onDisplayCompanionAd(companionEvent:CompanionAdDisplayEvent):void {
			doLogAndTrace("NOTIFICATION: Event received to display companion ad", companionEvent, Debuggable.DEBUG_DISPLAY_EVENTS);
        	_previousDivContent = new Array();
        	if(companionEvent.contentIsHTML()) {
				var previousContent:String = ExternalInterface.call("function(){ return document.getElementById('" + companionEvent.divID + "').innerHTML; }");
				_previousDivContent.push({ divId: companionEvent.divID, content: previousContent } );
				ExternalInterface.call("function(){ document.getElementById('" + companionEvent.divID + "').innerHTML='" + StringUtils.replaceSingleWithDoubleQuotes(companionEvent.content) + "'; }");
        	}
        	else {
        		//TO IMPLEMENT isImage(), isFlash(), isText()
        	}
        }

        public function onDisplayCompanionSWF(companionEvent:CompanionAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received to display companion ad (SWF)", Debuggable.DEBUG_DISPLAY_EVENTS);
        	// NOT IMPLEMENTED
        }

        public function onDisplayCompanionText(companionEvent:CompanionAdDisplayEvent):void {
			doLog("NOTIFICATION: Event received to display companion ad (Text)", Debuggable.DEBUG_DISPLAY_EVENTS);
        	// NOT IMPLEMENTED
        }
        
		public function onHideCompanionAd(companionEvent:CompanionAdDisplayEvent):void {
            doLogAndTrace("NOTIFICATION: Request received to hide companion ad", companionEvent, Debuggable.DEBUG_DISPLAY_EVENTS);
            
			var companionAd:CompanionAd = companionEvent.ad as CompanionAd;
			doLog("Event trigger received to hide the companion Ad with ID " + companionAd.id, Debuggable.DEBUG_CUEPOINT_EVENTS);
			for(var i:int=0; i < _previousDivContent.length; i++) {
				ExternalInterface.call("function(){ document.getElementById('" + _previousDivContent[i].divId + "').innerHTML='" + StringUtils.removeControlChars(_previousDivContent[i].content) + "'; }");				
			}
			_previousDivContent = new Array();            
		}

        // VAST tracking actions

        private function onSeekEvent(playerEvent:PlayerEvent):void {
        	if(_vastController != null) _vastController.onPlayerSeek(_player.playlist.currentIndex);
        }

		private function onMuteEvent(playerEvent:PlayerEvent):void {
        	if(_vastController != null) _vastController.onPlayerMute(_player.playlist.currentIndex);
		}

		private function onUnmuteEvent(playerEvent:PlayerEvent):void {
        	if(_vastController != null) _vastController.onPlayerUnmute(_player.playlist.currentIndex);
		}

		private function onPlayEvent(playerEvent:PlayerEvent):void {
        	if(_vastController != null) _vastController.onPlayerPlay(_player.playlist.currentIndex);			
		}

		private function onStopEvent(playerEvent:PlayerEvent):void {
        	if(_vastController != null) _vastController.onPlayerStop(_player.playlist.currentIndex);
		}
		
		private function onFullScreen(playerEvent:PlayerEvent):void {
        	if(_vastController != null) _vastController.onPlayerResize(_player.playlist.currentIndex);
		}

		private function onFullScreenExit(playerEvent:PlayerEvent):void {
//        	if(_vastController != null) _vastController.onPlayerResize(_player.playlist.currentIndex);			
		}

        private function onProcessVolumeEvent(playerEvent:PlayerEvent):void {
        	if(_player.volume == 0) {
        		_wasZeroVolume = true;
        		onMuteEvent(playerEvent);
        	}
        	else {
        		if(_wasZeroVolume) {
        			onUnmuteEvent(playerEvent);
        		}
        		_wasZeroVolume = false;
        	}
        }

		// DEBUG METHODS
	
		protected function doLog(data:String, level:int=1):void {
			Debuggable.getInstance().doLog(data, level);
		}
		
		protected function doTrace(o:Object, level:int=1):void {
			Debuggable.getInstance().doTrace(o, level);
		}
		
		protected function doLogAndTrace(data:String, o:Object, level:int=1):void {
			Debuggable.getInstance().doLogAndTrace(data, o, level);
		}
	}
}
