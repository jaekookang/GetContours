function p = DotsTrack(fName, p0, varargin)
%DOTSTRACK  - track features through an image sequence
%
%	usage:  p = DotsTrack(fName, p0, ...)
%
% this procedure tracks a set of interactively selected image features (such as blue dots)
% through an image sequence specified by movie FNAME
%
% close the window while paused to return P, an array-of-structs for tracked points with fields
%   POS    - [X,Y] (pixel coordinates, relative to ULC origin)
%   LABEL  - point id string
%   FRAME  - 1-based frame number of fitted image (FRAME and TIME valid only for first point of set)
%   TIME   - 0-based offset of frame from beginning of movie in seconds
%   STATUS - []: untracked; 0: valid; 1: failed tracking step; 2: user flagged invalid pt (tracking skipped)
%   CONF   - tracking step confidence value
%
% initial P0 [1 x nPoints] as returned by DOTSPLACE or an existing series [nFrames x nPoints] 
% as returned by a previous call to DOTSTRACK (in this case only existing frames can be modified)
% by default will resume processing from the last completed frame; specify FRAMES to override
%
% the procedure will pause and display any frame where it has failed to successfully track
% a point; in this frame the problematic location(s) will be displayed as a red "+" symbol
% click within its expected tracking location to update
%
% right click on a point to toggle its status:  'invalid' points are ignored during tracking
%
% optional 'NAME',VALUE parameters:
%   FRAMES  - constrain tracking to these frame numbers (default all)
%   PARAMS  - override point tracker parameters (cf. help vision.pointTracker)
%   TIMES   - constrain tracking to these intevals (secs); [nInts x start,stop]
%   XFORM   - conditioning function applied to each frame (e.g., @(img) 255-uint8(mean(img,3)))
%
% to extract points as an [nFrames x X,Y x nPoints] array:
%   p(cellfun(@isempty,{p(:,1).POS}),:) = [];  % delete trailing empty frames
%   xy = permute(reshape(cell2mat({p.POS}),[2,size(p,1),size(p,2)]),[2 1 3]); 
%   figure; pp2(xy); set(gca,'ydir','reverse'); legend({p(1,:).LABEL})
%
% to plot CONF:
%   c = reshape(cell2mat({p(:,:).CONF}),size(p,2),size(p,1))'; figure; pp1(c);
%
% requires Computer Vision Toolbox
%
% see also DOTSPLACE, DOTSPLOT

% mkt 01/15
% mkt 10/15 support for names and structured points arrays
% mkt 06/17 allow stepping without tracking (to move through invalid regions)
% mkt 06/18 fix overrun on specified frames

% callback handlers
if nargin < 2, eval('help DotsTrack'); return; end;
if nargin >= 3,
	switch varargin{1},
		case 'CBPAUSE',		% B0 pressed; interrupt active tracking
			set(varargin{2},'value',1);		% tbh
			return;
		case 'CBBTNGRP',	% button group selection change
			set(gcbf,'userData',get(p0.NewValue,'userData'));
			uiresume;
			return;
		case 'CBMENU',		% validity popup:  change status (0 valid, 1 invalid)
			if strcmp(get(gcbo,'checked'),'on'),
				set(gcbo,'checked','off'); n = logical(0);
				set(get(gcbo,'userdata'),'color','g');
			else
				set(gcbo,'checked','on'); n = logical(1);
				set(get(gcbo,'userdata'),'color','k');
			end;
			invalid = get(gca,'userdata'); invalid(varargin{2}) = n; set(gca,'userdata',invalid);
			return;
		otherwise,			% fall through
	end;
end;

% parse args
frames = [];
times = [];
params = {'MaxBidirectionalError',3};
xform = [];
for ai = 2 : 2 : length(varargin),
	switch upper(varargin{ai-1}),
		case 'FRAMES', frames = varargin{ai};
		case 'TIMES', times = varargin{ai};
		case 'PARAMS', params = varargin{ai};
		case 'XFORM', xform = varargin{ai};
		otherwise, error('unrecognized parameter (%s)', varargin{ai-1});
	end;
end;

% open the movie
try, mh = VideoReader(fName); catch, error('unable to open movie file %s', fName); end;
if verLessThan('matlab','8.5.0'),
	nFrames = get(mh,'NumberOfFrames');
	frameRate = get(mh,'FrameRate');
else,
	frameRate = mh.FrameRate;
	nFrames = floor(mh.Duration*frameRate);
end;

% map times to frames (ignore if frames also specified)
if ~isempty(times) && isempty(frames),
	f = floor(times*frameRate)+1;
	for k = 1 : size(f,1), frames = [frames , f(k,1):f(k,2)]; end;
end;
frames(frames > nFrames) = [];		% delete out-of-range frames

if size(p0,1) == 1,			% point template
	if isempty(frames), frames = [1:nFrames]; end;
	p(length(frames),size(p0,2)) = p0(1);
	p(end,end).POS = []; p(end,end).LABEL = [];
	p(1,:) = p0;
	for fi = 1 : length(frames),
		p(fi,1).FRAME = frames(fi);
		p(fi,1).TIME = (frames(fi)-1)/frameRate;
	end;
else,						% point series:  make sure requested frames available
	p = p0;
	pFrames = cell2mat({p(:,1).FRAME});
	if isempty(frames),
		frames = pFrames;
	else,
		unknownFrames = setdiff(frames,pFrames);
		if ~isempty(unknownFrames),
			unknownFrames
			error('FRAMES not found in P0 series');
		end;
	end;
end;
if length(frames) > length(unique(frames)),
	error('FRAMES contains duplicates (must be unique)');
end;
if isempty(frames),
	error('no specified FRAMES available in %s', fName);
end;

% get starting frame
if size(p0,1) == 1,
	idx = 1;
else,
	k = find(cellfun(@isempty,{p.STATUS}),1);
	if isempty(k), idx = 1; else idx = k-1; end;	% last non-empty frame
end;

% display the first image
img = GetMovieFrame(mh,frames(idx));
if ~isempty(xform), f = xform{1}; a = xform(2:end); img = f(img,a{:}); end;
[fh,ih] = implot(img);
set(fh,'userdata',0,'menubar','none');

% display markers
xy = cell2mat({p(idx,:).POS}');
invalid = cell2mat({p(idx,:).STATUS});
if isempty(invalid),
	invalid = logical(zeros(1,size(p,2)));	% assume all untracked points valid initially
else,
	invalid = logical(bitget(invalid,2));	% bit two defines user-specified invalidity
end;
set(gca,'userdata',invalid);			% gca userdata holds copy of invalid map
labels = {p(idx,:).LABEL};
m = uicontextmenu; uimenu(m,'label','one'); uimenu(m,'label','two','callback','disp(gcbo)');
colors = 'cgrkm';		% provisional, good, bad track, invalid, bad+invalid
checked = {'off','on'};	% valid, invalid
for k = 1 : length(labels),
	m = uicontextmenu;				% menu handle userdata points to line handle for color change in callback
	hh(k) = uimenu(m,'label','INVALID','checked',checked{invalid(k)+1},'callback',{@DotsTrack,'CBMENU',k});
	if isempty(p(idx,k).STATUS), c = 1; else, c = p(idx,k).STATUS+2; end;
	lh(k) = line(xy(k,1),xy(k,2),'color',colors(c),'marker','+','linestyle','none','TAG','DTRK','uicontextmenu',m);
	set(hh(k),'userdata',lh(k));
	th(k) = text(xy(k,1),xy(k,2),['  ',labels{k}],'color','w','TAG','DTRK','uicontextmenu',m,'interpreter','none');
end

% init controls:  gcf userdata maps state
bgh = uibuttongroup(fh,'units','pixels','position',[5 5 131 20]);
uicontrol(bgh,'style','togglebutton','position',[2 2 25 15],'string','<<','userdata',-2);
uicontrol(bgh,'style','pushbutton','position',[27 2 25 15],'string','<','callback','set(gcbf,''userdata'',-1);uiresume');
b0 = uicontrol(bgh,'style','togglebutton','position',[52 2 25 15],'string','O','userdata',0);
uicontrol(bgh,'style','pushbutton','position',[77 2 25 15],'string','>','callback','set(gcbf,''userdata'',1);uiresume');
uicontrol(bgh,'style','togglebutton','position',[102 2 25 15],'string','>>','userdata',2);
set(bgh,'SelectedObject',b0,'SelectionChangeFcn',{@DotsTrack,'CBBTNGRP'},'interruptible','on');
bh = bgh;

bh(2) = uicontrol(fh,'style','edit','position',[5 27 51 18],'horizontalAlignment','right','enable','inactive','string','Frame: ');
bh(3) = uicontrol(fh,'style','edit','position',[54 27 81 18],'horizontalAlignment','left', ...
			'string',sprintf(' %04d',frames(1)),'callback','set(gcbf,''userdata'',3);uiresume');
bh(4) = uicontrol(fh,'style','togglebutton','position',[5 47 73 20],'string','PAUSED','value',1,'callback','uiresume');
bh(5) = uicontrol(fh,'style','pushbutton','position',[78 47 58 20],'string','MODIFY','callback','set(gcbf,''userdata'',4);uiresume');

efh = bh(3);		% frame field alias
tbh = bh(4);		% tracking button alias

% allow b0 to turn off active tracking (broken in earlier versions)
if ~verLessThan('matlab','8.5.0'),
	set(b0,'callback',{@DotsTrack,'CBPAUSE',tbh});
end;

% initialize the tracker
pt = vision.PointTracker;
set(pt,params{:});
xy(invalid,:) = [];
initialize(pt,xy,img);

% tracking loop
oIdx = idx;				% last valid index
while 1,
	if ~ishandle(fh), break; end;

% handle paused
	if get(tbh,'value'),
		set(tbh,'string','PAUSED');
		while 1,
			state = get(fh,'userData');
			switch state,
				case {-2,-1}, 	% reverse
					idx = idx - 1; 
					if idx < 1, idx = 1; state = 0; end;
				case 0,			% stop cycling
				case {1,2}, 	% forward
					idx = idx + 1; 
					if idx > length(frames), idx = length(frames); state = 0; end;
				case 3,			% frame field
					f = round(str2num(get(efh,'string')));
					[~,idx] = min(abs(frames-f)); 
				case 4,			% modify point locations
					set(fh,'name',sprintf('ADJUST DOTS IN FRAME %d...',frames(idx)));
					set(lh,'visible','off');
					set(th,'visible','off');
					set(bh,'visible','off');
					invalid = get(gca,'userdata');
					p(idx,:) = DotsPlace(img,'IH',ih,'P0',p(idx,:));
					oIdx = idx;
					set(gca,'userdata','invalid');
					xy = cell2mat({p(idx,:).POS}');
					set(lh,'XData',xy(:,1),'YData',xy(:,2));
					for k = 1 : size(xy,1), set(th(k),'position',xy(k,:)); end;
					set(bh,'visible','on');
					set(th,'visible','on');
					set(lh,'visible','on');
					set(fh,'name',sprintf('%s  FRAME %04d / %04d  (%.3f secs)', fName, frames(idx), frames(end), p(idx,1).TIME));
			end;

% process new frame
			if isempty(idx),
				idx = oIdx;
				state = 0;
				set(efh,'string',sprintf(' %04d',frames(idx)));
			else,
				img = GetMovieFrame(mh,frames(idx));
				if ~isempty(xform), f = xform{1}; a = xform(2:end); img = f(img,a{:}); end;
				set(ih,'cdata',img);
				set(efh,'string',sprintf(' %04d',frames(idx)));
				set(fh,'name',sprintf('%s  FRAME %04d / %04d  (%.3f secs)', fName, frames(idx), frames(end), p(idx,1).TIME));
				if isempty(p(idx,1).POS),		% update frame using last available point locations
					xy = cell2mat({p(oIdx,:).POS}');
				else,							% update frame from existing point locations
					oIdx = idx;
					xy = cell2mat({p(idx,:).POS}');	
				end;
				for k = 1 : size(xy,1), 
					if isempty(p(idx,k).STATUS), c = 1; else, c = p(idx,k).STATUS+2; end;
					set(lh(k),'XData',xy(k,1),'YData',xy(k,2),'color',colors(c));
					set(th(k),'position',xy(k,:)); 
				end;
			end;
			if abs(state) == 2,		% rrev or ffwd
				drawnow;
			else,
				state = 0;			% wait for event
				set(fh,'userdata',0);
				set(bgh,'SelectedObject',b0);
				if ~isempty(p(idx,1).STATUS), 
					invalid = logical(bitget(cell2mat({p(idx,:).STATUS}),2));
					set(gca,'userdata',invalid);
					for k = 1 : length(invalid), set(hh(k),'checked',checked{invalid(k)+1}); end;
				end;
				
				uiwait(fh);
				
				if ~ishandle(fh), break; end;
				invalid = get(gca,'userdata');
				if ~get(tbh,'value'), 	% restart tracking
					if isempty(p(idx,1).POS),		% update frame using last available point locations
						xy = cell2mat({p(oIdx,:).POS}');
					else,							% update frame from existing point locations
						xy = cell2mat({p(idx,:).POS}');	
					end;
					xy(invalid,:) = [];
					release(pt);
					initialize(pt,xy,img);
					set(tbh,'string','TRACKING...');		% restart tracking
					break; 
				elseif (4 == get(fh,'userdata')),			% modify
					set(fh,'name',sprintf('ADJUST DOTS IN FRAME %d...',frames(idx)));
					set(lh,'visible','off');
					set(th,'visible','off');
					set(bh,'visible','off');
					invalid = get(gca,'userdata');
					if isempty(p(idx,1).POS), p(idx,:) = p(oIdx,:); end;
					p(idx,:) = DotsPlace(img,'IH',ih,'P0',p(idx,:));
					oIdx = idx;
					set(gca,'userdata',invalid);
					xy = cell2mat({p(idx,:).POS}');
					set(lh,'XData',xy(:,1),'YData',xy(:,2));
					for k = 1 : size(xy,1), set(th(k),'position',xy(k,:)); end;
					set(bh,'visible','on');
					set(th,'visible','on');
					set(lh,'visible','on');
					set(fh,'name',sprintf('%s  FRAME %04d / %04d  (%.3f secs)', fName, frames(idx), frames(end), p(idx,1).TIME), 'userdata',0);					
				end;
			end;
		end;

% tracking active
	else,
		img = GetMovieFrame(mh,frames(idx));
		if ~isempty(xform), f = xform{1}; a = xform(2:end); img = f(img,a{:}); end;
		set(ih,'cdata',img);
		set(efh,'string',sprintf(' %04d',frames(idx)));
		set(fh,'userdata',0,'name',sprintf('%s  FRAME %04d / %04d  (%.3f secs)', fName, frames(idx), frames(end), p(idx,1).TIME));
		[xy,v,conf] = step(pt,img);		% step the tracker, returning new points, validity, and confidence

% map tracked points onto full set (if any user-marked as invalid)
		if any(invalid),
			fxy = cell2mat({p(idx,:).POS}');
			if isempty(fxy), fxy = cell2mat({p(oIdx,:).POS}'); end;
			fv = ones(1,size(p,2));
			fc = zeros(1,size(p,2));
			k = find(~invalid);
			fxy(k,:) = xy;
			fv(k) = v;
			fc(k) = conf;
			xy = fxy; v = fv; conf = fc;
		end;

% update point info
		p(idx,1).FRAME = frames(idx);
		p(idx,1).TIME = (frames(idx)-1)/frameRate;
		for k = 1 : size(p,2),
			p(idx,k).STATUS = uint8(~v(k)) + uint8(2*invalid(k));
			set(lh(k),'XData',xy(k,1),'YData',xy(k,2),'color',colors(p(idx,k).STATUS+2));
			set(th(k),'position',xy(k,:)); 
			p(idx,k).POS = xy(k,:);
			p(idx,k).LABEL = labels{k};
			p(idx,k).CONF = conf(k);
		end;
		drawnow;

% fix mistrackings
		if any(~v),
			set(fh,'name',sprintf('RESET INVALID DOTS IN FRAME %d...',frames(idx)));
			set(lh,'visible','off');
			set(th,'visible','off');
			set(bh,'visible','off');
			p(idx,:) = DotsPlace(img,'IH',ih,'P0',p(idx,:));
			if ~ishandle(fh), break; end;
			for k = 1 : size(p,2), p(idx,k).STATUS = bitand(p(idx,k).STATUS,2); end;
			xy = cell2mat({p(idx,:).POS}');
			set(lh,'XData',xy(:,1),'YData',xy(:,2));
			for k = 1 : size(xy,1), set(th(k),'position',xy(k,:)); end;
			set(bh,'visible','on');
			set(th,'visible','on');
			set(lh,'visible','on');
			set(tbh,'value',1);		% force pause
			oIdx = idx;
			continue;
		else,
			xy(invalid,:) = [];
		end;
		oIdx = idx;
		idx = idx + 1;			% step frame index
		if idx > length(frames),
			idx = length(frames);
			set(tbh,'value',1);		% force pause
		end;
	end;
end;

release(pt);
delete(pt);
delete(mh);
