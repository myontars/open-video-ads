/*    
 *    Copyright (c) 2009 Open Video Ads - Option 3 Ventures Limited
 *
 *    This file is part of the Open Video Ads VAST framework.
 *
 *    The VAST framework is free software: you can redistribute it 
 *    and/or modify it under the terms of the GNU General Public License 
 *    as published by the Free Software Foundation, either version 3 of 
 *    the License, or (at your option) any later version.
 *
 *    The VAST framework is distributed in the hope that it will be 
 *    useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU General Public License for more details.
 *
 *    You should have received a copy of the GNU General Public License
 *    along with the framework.  If not, see <http://www.gnu.org/licenses/>.
 */
 package org.openvideoads.vast.playlist.smil {
	import org.openvideoads.vast.playlist.DefaultPlaylist;
	import org.openvideoads.vast.schedule.StreamSequence;
	
	/**
	 * @author Paul Schulz
	 */
	public class SMILPlaylist extends DefaultPlaylist {		
		
		public function SMILPlaylist(streamSequence:StreamSequence) {
			super(streamSequence);
		}
		
		public override function getModel():Array {
			return new Array();
		}

		public override function toString():String {
			return new String();
		}
	}
}