;
; Copyright (c) 2013-2024, Marc De Graef Research Group/Carnegie Mellon University
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
; EMsoft:EBSDreaddatafile.pro
;--------------------------------------------------------------------------
;
; PROGRAM: EBSDreaddatafile.pro
;
;> @author Marc De Graef, Carnegie Mellon University
;
;> @brief Reads the data files produced by the CTEMMC.f90 and CTEMEBSDmaster.f90 programs
;
; THIS FILE FORMAT OPTION HAS BEEN DELETED FROM THIS PROGRAM !!!!!
;
;> @date 03/19/14 MDG 1.0 first attempt 
;> @date 10/31/15 MDG 2.0 routine removed from package; kept in folder for now...
;--------------------------------------------------------------------------
pro EBSDreaddatafile,MCFILE=MCFILE,MPFILE=MPFILE
;
;------------------------------------------------------------
; common blocks
common SEM_widget_common, SEMwidget_s
common SEM_data_common, SEMdata

; the next common block contains all the raw data needed to generate the EBSD patterns
common EBSD_rawdata, accum_e, accum_z, mLPNH, mLPSH


  Core_Print,' ',/blank
  SEMdata.MCMPboth = 0

if keyword_set(MPFILE) then begin
  Core_Print,'Reading data file '+SEMdata.mpfilename

  openu,1,SEMdata.pathname+'/'+SEMdata.mpfilename,/f77
; first a string of 132 characters
  progname = bytarr(132)
  readu,1,progname
  progname = strtrim(string(progname))
    Core_Print,' ->File generated by program '+progname+'<-'

; version string
  scversion = bytarr(8)
  readu,1,scversion
  SEMdata.scversion = strtrim(string(scversion))
    Core_Print,'Version identifier : '+string(scversion) 

; display the file size in Mb 
  WIDGET_CONTROL, SET_VALUE=string(float(SEMdata.mpfilesize)/1024./1024.,FORMAT="(F8.2)")+' Mb', SEMwidget_s.mpfilesize

; structure file name
  xtalname = bytarr(132)
  readu,1,xtalname
  SEMdata.xtalname = strtrim(string(xtalname))
    Core_Print,'Xtalname = ->'+SEMdata.xtalname+'<-'
  WIDGET_CONTROL, SET_VALUE=SEMdata.xtalname, SEMwidget_s.xtalname

; energy file name
  energyname = bytarr(132)
  readu,1,energyname
  res = strtrim(string(energyname))
  finfo = file_info(res)
  SEMdata.mcfilesize = finfo.size

  spos = strpos(res,'/',/reverse_search)
  dpos = strpos(res,'.',/reverse_search)
  plen = strlen(res)
  SEMdata.mcpathname = strmid(res,0,spos)
  SEMdata.mcfilename = strmid(res,spos+1)
    Core_Print,'MC filename = ->'+SEMdata.mcfilename+'<-'
  WIDGET_CONTROL, SET_VALUE=SEMdata.mcfilename, SEMwidget_s.mcfilename

; npx, npy, numEbins, numset
  dims = lonarr(4)
  readu,1,dims
  SEMdata.mpimx = dims[0]
  SEMdata.mpimy = dims[1]
  SEMdata.mcenergynumbin = dims[2]
  SEMdata.numset= dims[3]
  SEMdata.Asymsel = -1

  WIDGET_CONTROL, SET_VALUE=string(2*dims[0]+1,format="(I5)"), SEMwidget_s.mpimx
  WIDGET_CONTROL, SET_VALUE=string(2*dims[1]+1,format="(I5)"), SEMwidget_s.mpimy
  WIDGET_CONTROL, SET_VALUE=string(dims[2],format="(I5)"), SEMwidget_s.mcenergynumbin
  
; energy levels
  EkeVs = fltarr(SEMdata.mcenergynumbin)
  readu,1,EkeVs

; atomic numbers for asymmetric unit
  atnum = lonarr(SEMdata.numset)
  readu,1,atnum
  SEMdata.atnum(0:SEMdata.numset-1) = atnum(0:SEMdata.numset-1)

; Lambert projection type
  Ltype = bytarr(6)
  readu,1,Ltype
  Ltype = strtrim(string(Ltype))
  if (Ltype eq 'hexago') then SEMdata.mpgridmode = ' Hexagonal' else SEMdata.mpgridmode = ' Square'
  WIDGET_CONTROL, SET_VALUE=SEMdata.mpgridmode, SEMwidget_s.mpgridmode

; and finally the results array
  MParray = fltarr(2L*SEMdata.mpimx+1L,2L*SEMdata.mpimy+1L,SEMdata.mcenergynumbin,SEMdata.numset)
  readu,1,MParray
  if (SEMdata.numset gt 1) then MParraysum = total(MParray,4) else MParraysum = MParray

  sz = size(MParray,/dimensions)
  if (SEMdata.numset gt 1) then Core_Print,' Size of MParray data array : '+string(sz[0],format="(I5)")+' x'+string(sz[1],format="(I5)") +' x'+string(sz[2],format="(I5)") +' x'+string(sz[3],format="(I5)") else Core_Print,' Size of MParray data array : '+string(sz[0],format="(I5)")+' x'+string(sz[1],format="(I5)") +' x'+string(sz[2],format="(I5)")

; and close the file
  close,1

; and initialize the coordinate arrays for the Lambert transformation
  Core_LambertS2C,reform(MParray[*,*,0,0]),/mp
  Core_LambertS2SP,reform(MParray[*,*,0,0]),/mp

   WIDGET_CONTROL, SEMwidget_s.MPbutton, sensitive=1
   WIDGET_CONTROL, SEMwidget_s.detector, sensitive=1
  SEMdata.MCMPboth = 1
endif






; read the Monte Carlo data file
if (keyword_set(MCFILE) or (SEMdata.MCMPboth eq 1)) then begin
  Core_Print,'Reading data file '+SEMdata.mcfilename
  SEMdata.Esel = 0

  openu,1,SEMdata.mcpathname+'/'+SEMdata.mcfilename,/f77
; first a string of 132 characters
  progname = bytarr(132)
  readu,1,progname
  progname = strtrim(string(progname))
    Core_Print,' ->File generated by program '+progname+'<-'

; version string
  scversion = bytarr(8)
  readu,1,scversion
  SEMdata.scversion = strtrim(string(scversion))
    Core_Print,'Version identifier : '+string(scversion) 

; display the file size in Mb 
  WIDGET_CONTROL, SET_VALUE=string(float(SEMdata.mcfilesize)/1024./1024.,FORMAT="(F8.2)")+' Mb', SEMwidget_s.mcfilesize

; version identifier 3_x_x is single structure file
; version identifier 3_y_y is two-layer file

 if (SEMdata.scversion eq '3_x_x') then begin ; scversion = 3_x_x
; structure file name
  xtalname = bytarr(132)
  readu,1,xtalname
  SEMdata.xtalname = strtrim(string(xtalname))
    Core_Print,'Xtalname = ->'+SEMdata.xtalname+'<-'
  WIDGET_CONTROL, SET_VALUE=SEMdata.xtalname, SEMwidget_s.xtalname

; six integers parameters (last one is not needed)
; dims = lonarr(6)
  dims = lonarr(5)
  readu,1,dims
  SEMdata.mcenergynumbin = dims[0]
  SEMdata.mcdepthnumbins = dims[1]
  SEMdata.mcimx = (dims[2]-1L)/2L
  SEMdata.mcimy = (dims[3]-1L)/2L
  SEMdata.mctotale = dims[4]

  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(I5)"), SEMwidget_s.mcenergynumbin
  WIDGET_CONTROL, SET_VALUE=string(dims[1],format="(I5)"), SEMwidget_s.mcdepthnumbins
  WIDGET_CONTROL, SET_VALUE=string(dims[2],format="(I5)"), SEMwidget_s.mcimx
  WIDGET_CONTROL, SET_VALUE=string(dims[3],format="(I5)"), SEMwidget_s.mcimy
  WIDGET_CONTROL, SET_VALUE=string(dims[4],format="(I12)"), SEMwidget_s.mctotale

; 5 more parameters, all doubles
  dims = dblarr(5)
  readu,1,dims
  SEMdata.mcenergymax = dims[0]
  SEMdata.mcenergymin = dims[1]
  SEMdata.mcenergybinsize = dims[2]
  SEMdata.mcdepthmax = dims[3]
  SEMdata.mcdepthstep = dims[4]

  SEMdata.voltage = SEMdata.mcenergymax

  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(F7.2)"), SEMwidget_s.mcenergymax
  WIDGET_CONTROL, SET_VALUE=string(dims[1],format="(F7.2)"), SEMwidget_s.mcenergymin
  WIDGET_CONTROL, SET_VALUE=string(dims[2],format="(F7.2)"), SEMwidget_s.mcenergybinsize
  WIDGET_CONTROL, SET_VALUE=string(dims[3],format="(F7.2)"), SEMwidget_s.mcdepthmax
  WIDGET_CONTROL, SET_VALUE=string(dims[4],format="(F7.2)"), SEMwidget_s.mcdepthstep
  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(F7.2)"), SEMwidget_s.voltage

; sample tilt angles
  dims = dblarr(2)
  readu,1,dims
  SEMdata.mcvangle = dims[0]
  SEMdata.mchangle = dims[1]

  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(F7.2)"), SEMwidget_s.mcvangle
  WIDGET_CONTROL, SET_VALUE=string(dims[1],format="(F7.2)"), SEMwidget_s.mchangle

; Monte Carlo mode  'CSDA' or 'Discrete losses'
  mcm = bytarr(4)
  readu,1,mcm
  mcm = strtrim(string(mcm))
  if (mcm eq 'CSDA') then SEMdata.mcmode = 'CSDA' else SEMdata.mcmode = 'DLOS'
  WIDGET_CONTROL, SET_VALUE=SEMdata.mcmode, SEMwidget_s.mcmode


; and finally, we read the actual data arrays accum_e and accum_z
  accum_e = lonarr(SEMdata.mcenergynumbin, 2*SEMdata.mcimx+1,2*SEMdata.mcimy+1)
  accum_z = lonarr(SEMdata.mcenergynumbin, SEMdata.mcdepthnumbins, 2*(SEMdata.mcimx/10)+1,2*(SEMdata.mcimy/10)+1)
  readu,1,accum_e
  readu,1,accum_z

; total number of BSE electrons
  SEMdata.mcbse = total(accum_e)
  WIDGET_CONTROL, SET_VALUE=string(SEMdata.mcbse,format="(I12)"), SEMwidget_s.mcbse


  sz = size(accum_e,/dimensions)
    Core_Print,' Size of accum_e data array : '+string(sz[0],format="(I5)")+' x'+string(sz[1],format="(I5)")+' x'+string(sz[2],format="(I5)")
  sz = size(accum_z,/dimensions)
    Core_Print,' Size of accum_z data array : '+string(sz[0],format="(I5)")+' x'+string(sz[1],format="(I5)") +' x'+string(sz[2],format="(I5)") +' x'+string(sz[3],format="(I5)")

; and close the file
  close,1

end else begin  ; scversion = 3_y_y

; structure file name
  xtalname = bytarr(132)
  xtalname2 = bytarr(132)
  readu,1,xtalname
  readu,1,xtalname2
  SEMdata.xtalname = strtrim(string(xtalname))
  SEMdata.xtalname2 = strtrim(string(xtalname2))
    Core_Print,'Xtalname = ->'+SEMdata.xtalname+'<-'
    Core_Print,'Xtalname2 = ->'+SEMdata.xtalname2+'<-'
  WIDGET_CONTROL, SET_VALUE=SEMdata.xtalname, SEMwidget_s.xtalname+'/'+SEMwidget_s.xtalname2

; dimensions
  dims = lonarr(4)
  mctotale = 0LL
  readu,1,dims,mctotale
  SEMdata.mcenergynumbin = dims[0]
  SEMdata.mcdepthnumbins = dims[1]
  SEMdata.mcimx = (dims[2]-1L)/2L
  SEMdata.mcimy = (dims[3]-1L)/2L
  SEMdata.mctotale = mctotale


  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(I5)"), SEMwidget_s.mcenergynumbin
  WIDGET_CONTROL, SET_VALUE=string(dims[1],format="(I5)"), SEMwidget_s.mcdepthnumbins
  WIDGET_CONTROL, SET_VALUE=string(dims[2],format="(I5)"), SEMwidget_s.mcimx
  WIDGET_CONTROL, SET_VALUE=string(dims[3],format="(I5)"), SEMwidget_s.mcimy
  WIDGET_CONTROL, SET_VALUE=string(mctotale,format="(I12)"), SEMwidget_s.mctotale

; 5 more parameters, all doubles
  dims = dblarr(5)
  readu,1,dims
  SEMdata.mcenergymax = dims[0]
  SEMdata.mcenergymin = dims[1]
  SEMdata.mcenergybinsize = dims[2]
  SEMdata.mcdepthmax = dims[3]
  SEMdata.mcdepthstep = dims[4]

  SEMdata.voltage = SEMdata.mcenergymax

  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(F7.2)"), SEMwidget_s.mcenergymax
  WIDGET_CONTROL, SET_VALUE=string(dims[1],format="(F7.2)"), SEMwidget_s.mcenergymin
  WIDGET_CONTROL, SET_VALUE=string(dims[2],format="(F7.2)"), SEMwidget_s.mcenergybinsize
  WIDGET_CONTROL, SET_VALUE=string(dims[3],format="(F7.2)"), SEMwidget_s.mcdepthmax
  WIDGET_CONTROL, SET_VALUE=string(dims[4],format="(F7.2)"), SEMwidget_s.mcdepthstep
  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(F7.2)"), SEMwidget_s.voltage

; sample tilt angles
  dims = dblarr(2)
  readu,1,dims
  SEMdata.mcvangle = dims[0]
  SEMdata.mchangle = dims[1]

  WIDGET_CONTROL, SET_VALUE=string(dims[0],format="(F7.2)"), SEMwidget_s.mcvangle
  WIDGET_CONTROL, SET_VALUE=string(dims[1],format="(F7.2)"), SEMwidget_s.mchangle

; film thickness
  ft = 0.0
  readu,1,ft
  SEMdata.mcfilmthickness = ft
  WIDGET_CONTROL, SET_VALUE=string(ft,format="(F7.2)"), SEMwidget_s.mcfilmthickness

; Monte Carlo mode  'CSDA' or 'Discrete losses'
  mcm = bytarr(4)
  readu,1,mcm
  mcm = strtrim(string(mcm))
  if (mcm eq 'CSDA') then SEMdata.mcmode = 'CSDA' else SEMdata.mcmode = 'DLOS'
  WIDGET_CONTROL, SET_VALUE=SEMdata.mcmode, SEMwidget_s.mcmode


; and finally, we read the actual data arrays accum_e and accum_z
  accum_e = lonarr(SEMdata.mcenergynumbin, 2*SEMdata.mcimx+1,2*SEMdata.mcimy+1)
  accum_z = lonarr(SEMdata.mcenergynumbin, SEMdata.mcdepthnumbins, 2*SEMdata.mcimx/10+1,2*SEMdata.mcimy/10+1)
  readu,1,accum_e
  readu,1,accum_z

; total number of BSE electrons
  SEMdata.mcbse = total(accum_e)
  WIDGET_CONTROL, SET_VALUE=string(SEMdata.mcbse,format="(I12)"), SEMwidget_s.mcbse


  sz = size(accum_e,/dimensions)
    Core_Print,' Size of accum_e data array : '+string(sz[0],format="(I5)")+' x'+string(sz[1],format="(I5)")+' x'+string(sz[2],format="(I5)")
  sz = size(accum_z,/dimensions)
    Core_Print,' Size of accum_z data array : '+string(sz[0],format="(I5)")+' x'+string(sz[1],format="(I5)") +' x'+string(sz[2],format="(I5)") +' x'+string(sz[3],format="(I5)")

; and close the file
  close,1
end ; scversion if then else


; and initialize the coordinate arrays for the Lambert transformation
  Core_LambertS2C,reform(accum_e[0,*,*]),/mc
  Core_LambertS2SP,reform(accum_e[0,*,*]),/mc

; (de)activate buttons
   WIDGET_CONTROL, SEMwidget_s.MCbutton, sensitive=1
   if (SEMdata.MCMPboth eq 0) then begin
     WIDGET_CONTROL, SEMwidget_s.MPbutton, sensitive=0
     WIDGET_CONTROL, SEMwidget_s.detector, sensitive=0
     WIDGET_CONTROL, SET_VALUE=' ', SEMwidget_s.mpfilename
     WIDGET_CONTROL, SET_VALUE=' ', SEMwidget_s.mpfilesize
     WIDGET_CONTROL, SET_VALUE=' ', SEMwidget_s.mpimx
     WIDGET_CONTROL, SET_VALUE=' ', SEMwidget_s.mpimy
     WIDGET_CONTROL, SET_VALUE=' ', SEMwidget_s.mpgridmode
   endif
end


  Core_Print,'Completed reading data file(s)',/blank


skipall:

end
