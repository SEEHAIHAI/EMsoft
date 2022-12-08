;
; Copyright (c) 2013-2023, Marc De Graef Research Group/Carnegie Mellon University
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are 
; permitted provided that the following conditions are met:
;
;     - Redistributions of source code must retain the above copyright notice, this list 
;        of conditions and the following disclaimer.
;     - Redistributions in binary form must reproduce the above copyright notice, this 
;        list of conditions and the following disclaimer in the documentation and/or 
;        other materials provided with the distribution.
;     - Neither the names of Marc De Graef, Carnegie Mellon University nor the names 
;        of its contributors may be used to endorse or promote products derived from 
;        this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR 
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
; CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, 
; OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE 
; USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
; ###################################################################
;--------------------------------------------------------------------------
; CTEMsoft2013:STEMdetectorsetup.pro
;--------------------------------------------------------------------------
;
; PROGRAM: STEMdetectorsetup.pro
;
;> @author Marc De Graef, Carnegie Mellon University
;
;> @brief Creates a detector plot and inits a number of important variables
;
;> @date 06/20/13 MDG 1.0 first attempt 
;--------------------------------------------------------------------------
pro STEMdetectorsetup,darkfield=darkfield
;
; creates all the arrays needed for the segmented detector
; 
;------------------------------------------------------------
; common blocks
common STEM_widget_common, widget_s
common STEM_data_common, data
common STEM_detectordata, STEMdata, STEMcimage, BFdisk, DFdisk, clickablemap, STEMsectormaps, STEMsectors, STEMsectorranges
; the next common block contains all the raw data needed to generate the CBED patterns
common STEM_rawdata, indices, offsets, kperp, rawdata
; this one contains all the arrays needed to apply the BF and HAADF masks
common STEM_masks, ktpg, ktpgang, BFmask, HAADFmask, BFindices, HAADFindices, BFcnt, HAADFcnt
; and this one is used to create the blue channel of the detector plot
common STEM_circles, th, cth, sth, blue, diskpos


STEMdata = {STEMdatastruct, $
	dim: fix(401) $		; array size for display of detector plot
	}

; drawing will be in color
STEMcimage = bytarr(3,STEMdata.dim,STEMdata.dim)

; diffraction mode ?
if not keyword_set(darkfield) then begin

d2 = STEMdata.dim/2
dis = shift(dist(STEMdata.dim),d2,d2)

pixelradius = d2 

; we'll need to correct this for the camera length
BFpixel = pixelradius * (data.BFrho/data.patang)
DFipixel = pixelradius * (data.HAADFrhoin/data.patang)
DFopixel = pixelradius * (data.HAADFrhoout/data.patang)

; bright field detector
BFdisk = replicate(0B,STEMdata.dim,STEMdata.dim)
BFdisk[where(dis le BFpixel)] = 250B

; dark field detector
DFdisk = replicate(0B,STEMdata.dim,STEMdata.dim)
DFdisk[where((dis gt DFipixel) and (dis le DFopixel))] = 200B

; if detector is segmented, rotate and add the segment edges
w=2		; width of black edge used to delineate the sectors, needs to be scaled

if (data.detsegm gt 1) then begin
; delineate the sectors
  dtheta = 360.0/data.detsegm
  for i=0,data.detsegm-1 do begin
    DFdisk = rot(DFdisk,i*dtheta,missing=0B,cubic=-0.5)
    DFdisk[d2-w:d2+w,d2+DFipixel-w:d2+DFopixel+w] = 0B
    DFdisk = rot(DFdisk,-i*dtheta,missing=0B,cubic=-0.5)
  endfor
; do we also need to offset the segmented detector angle ?
  if (data.angsegm ne 0.0) then begin
    DFdisk = rot(DFdisk,data.angsegm,missing=0B,cubic=-0.5)
  end

; next we must make a sequenced map of all sectors, using 
; the value 0 for the BF sector, and 1 .. nseg for the 
; dark field sectors, going clockwise; we'll use this 
; as a clickable map, so the user can click on a sector 
; to display the image generated by that sector
  DFmap = DFdisk gt 0
  lDFmap = label_region(DFdisk)
  clickablemap = lDFmap

; next, renumber the sectors
  rad = (DFopixel+DFipixel)/2
  thw = 360.0/float(data.detsegm)/2.0
  th = data.angsegm + thw + findgen(data.detsegm) * dtheta
; offset by -90.0 to make the first sector the one that is at the top
  c = cos((th-90.0)*!dtor)
  s = -sin((th-90.0)*!dtor)

  for i=0,data.detsegm-1 do begin
    x = d2+c[i]*rad
    y = d2+s[i]*rad
    q = where(lDFmap eq lDFmap[x,y],cnt)
    if (cnt gt 0) then clickablemap[q] = i+1
  endfor

; finally, create the sector maps for rapid computation of the sector totals
  STEMsectormaps = replicate(0B,STEMdata.dim,STEMdata.dim,data.detsegm+1)
  for i=1,data.detsegm do begin
    sector = replicate(0B,STEMdata.dim,STEMdata.dim)
    q = where(clickablemap eq i)
    sector[q] = 1B 
    STEMsectormaps[0:*,0:*,i] = sector[0:*,0:*]
  endfor 

end else begin   ; detector is not segmented so the clickablemap is simple
  clickablemap = DFdisk gt 0
; finally, create the sector maps for rapid computation of the sector totals
  STEMsectormaps = replicate(0B,STEMdata.dim,STEMdata.dim,data.detsegm+1)
  sector = replicate(0B,STEMdata.dim,STEMdata.dim)
  q = where(clickablemap eq 1)
  sector[q] = 1B 
  STEMsectormaps[0:*,0:*,1] = sector[0:*,0:*]
end

; keep track of which sectors are currently active
STEMsectors = replicate(0B,data.detsegm+1)

; keep the angular ranges (in radians) of all detector segments (clockwise sector numbering)
STEMsectorranges = fltarr(2,data.detsegm+1)
if (data.detsegm eq 1) then begin
  STEMsectorranges[0:1,1] = [0.0,2.0*!pi]
end else begin
  startangle = 90.0 - data.angsegm 
  for i=1,data.detsegm do STEMsectorranges[0:1,i] = startangle-[i-1,i]*dtheta
  STEMsectorranges = (STEMsectorranges +720.0) mod 360.0
  STEMsectorranges *= !dtor
end

;print,'STEM detector segment angular ranges : '
;print,STEMsectorranges/!dtor

; red for BF detector, green for HAADF detector, blue will be used to highlight sectors
; and also, eventually, to draw the diffracted disks on the same sketch
STEMcimage[0,0:*,0:*] = BFdisk
STEMcimage[1,0:*,0:*] = DFdisk

wset,widget_s.detdrawID
tvscl,STEMcimage,true=1

; pre-compute the |k_t+g| array
; scale factor to go from nm-1 to pixels
if (data.srzamode eq 'ZA') then begin
  data.scale = 1000.0 * data.wavelength * (data.nums+1) * data.bragg / (data.thetac * sin(data.bragg))
end else begin
  data.scale = 0.5*1000.0 * data.wavelength * (data.nums+1) * data.bragg / (data.thetac * sin(data.bragg))
endelse

; |k_t + g| array in units of mrad; and the azimuthal angle for each point in radians
ktpg = fltarr(data.numref,data.numk)
ktpgang = fltarr(data.numref,data.numk)
for iref=0,data.numref-1 do begin
  for ibeam=0,data.numk-1 do begin
    ip = offsets[0,iref]*data.scale + kperp[0,ibeam]
    jp = offsets[1,iref]*data.scale + kperp[1,ibeam]
    d = 0.5*data.wavelength*sqrt(ip^2+jp^2)/data.scale
    ktpg[iref,ibeam] = 2000.0*asin(d)
    ang = atan(jp,ip)
    if (ang lt 0.0) then ang = ang + 2.0*!pi 
    ktpgang[iref,ibeam] = ang mod (2.0*!pi)
  endfor
endfor 

;print,transpose(ktpg[4,0:80])
;print,transpose(ktpgang[4,0:80])

; finally, we need to compute the pattern of diffraction disks for the current camera 
; length and superimpose it in the blue channel of the STEMcimage detector image.  
; this routine is called once here, and all other times from the CAMLEN case in STEMevent.pro
STEMdrawdisks

end else begin ; regular dark field mode is called for

; we need to compute the pattern of diffraction disks for the current camera 
; length and display it in the blue channel of the STEMcimage detector image.  
; we're calling this with the darkfield keyword, so that the routine will store 
; some intermediate results
STEMdrawdisks,/darkfield

endelse



end ; procedure
