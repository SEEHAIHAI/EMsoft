! ###################################################################
! Copyright (c) 2015-2016, Marc De Graef Research Group/Carnegie Mellon University
! All rights reserved.
!
! Redistribution and use in source and binary forms, with or without modification, are
! permitted provided that the following conditions are met:
!
!     - Redistributions of source code must retain the above copyright notice, this list
!        of conditions and the following disclaimer.
!     - Redistributions in binary form must reproduce the above copyright notice, this
!        list of conditions and the following disclaimer in the documentation and/or
!        other materials provided with the distribution.
!     - Neither the names of Marc De Graef, Carnegie Mellon University nor the names
!        of its contributors may be used to endorse or promote products derived from
!        this software without specific prior written permission.
!
! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
! ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
! LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
! USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
! ###################################################################

!--------------------------------------------------------------------------
! EMsoft:EMEBSDDI.f90
!--------------------------------------------------------------------------
!
! PROGRAM: EMEBSDDI
!
!> @author Saransh Singh/Marc De Graef, Carnegie Mellon University
!
!> @brief Indexing of EBSD patterns using the dictionary approach. Later, this program
!> will be used for dynamic pattern center correction to hopefully make
!> the dictionary indexing even more robust.
!
!> @date 03/25/15  SS 1.0 original
!> @date 02/02/16 MDG 1.1 significant changes to optimize the code
!> @date 02/04/16 MDG 1.2 added circular mask code
!> @date 03/10/16 MDG 1.3 added h5ebsd formatted output
!> @date 11/14/16 MDG 1.4 added code to read dictionary patterns from h5 file
!> @date 04/04/18 MDG 2.0 separated MC and MP name lists and data structures (all internal changes)
!--------------------------------------------------------------------------
program EMEBSDDI

use local
use typedefs
use NameListTypedefs
use NameListHandlers
use files
use io
use error
use initializers
use EBSDmod
use EBSDDImod
use HDF5
use HDFsupport

IMPLICIT NONE

character(fnlen)                            :: nmldeffile, progname, progdesc
type(EBSDIndexingNameListType)              :: dinl
type(MCCLNameListType)                      :: mcnl
type(EBSDMasterNameListType)                :: mpnl
type(EBSDNameListType)                      :: enl

type(EBSDMCdataType)                        :: EBSDMCdata
type(EBSDMPdataType)                        :: EBSDMPdata
type(EBSDDetectorType)                      :: EBSDdetector
logical                                     :: verbose
integer(kind=irg)                           :: istat, res, hdferr

interface
        subroutine MasterSubroutine(dinl, mcnl, mpnl, EBSDMCdata, EBSDMPdata, EBSDdetector, progname, nmldeffile)

        use local
        use typedefs
        use NameListTypedefs
        use NameListHandlers
        use files
        use dictmod
        use Lambert
        use others
        use crystal
        use initializersHDF
        use gvectors
        use filters
        use error
        use io
        use diffraction
        use symmetry
        use quaternions
        use constants
        use rotations
        use so3
        use math
        use EBSDmod
        use EBSDDImod
        use clfortran
        use CLsupport
        use omp_lib
        use HDF5
        use h5im
        use h5lt
        use HDFsupport
        use EMh5ebsd
        use NameListHDFwriters
        use ECPmod, only: GetPointGroup
        use Indexingmod
        use ISO_C_BINDING
        use timing

        IMPLICIT NONE

        type(EBSDIndexingNameListType),INTENT(INOUT)        :: dinl
        type(MCCLNameListType),INTENT(INOUT)                :: mcnl
        type(EBSDMasterNameListType),INTENT(INOUT)          :: mpnl
        type(EBSDMCdataType),INTENT(INOUT)                  :: EBSDMCdata
        type(EBSDMPdataType),INTENT(INOUT)                  :: EBSDMPdata
        type(EBSDDetectorType),INTENT(INOUT)                :: EBSDdetector
        character(fnlen),INTENT(IN)                         :: progname
        character(fnlen),INTENT(IN)                         :: nmldeffile

        end subroutine MasterSubroutine
end interface

nmldeffile = 'EMEBSDDI.nml'
progname = 'EMEBSDDI.f90'
progdesc = 'Program to index EBSD patterns using a dynamically calculated pattern dictionary'
verbose = .TRUE.

! print some information
call EMsoft(progname, progdesc)

! deal with the command line arguments, if any
call Interpret_Program_Arguments(nmldeffile,1,(/ 80 /), progname)

! deal with the namelist stuff
res = index(nmldeffile,'.nml',kind=irg)
if (res.eq.0) then
  call FatalError('EMEBSDIndexing','JSON input not yet implemented')
!  call JSONreadEBSDIndexingNameList(dinl, nmldeffile, error_cnt)
else
  call GetEBSDIndexingNameList(nmldeffile,dinl)
end if

! is this a dynamic calculation (i.e., do we actually compute the EBSD patterns)?
if (trim(dinl%indexingmode).eq.'dynamic') then 

    ! 1. read the Monte Carlo data file
    call h5open_EMsoft(hdferr)
    call readEBSDMonteCarloFile(dinl%masterfile, mcnl, hdferr, EBSDMCdata, getAccume=.TRUE.)

    ! 2. read EBSD master pattern file
    call readEBSDMasterPatternFile(dinl%masterfile, mpnl, hdferr, EBSDMPdata, getmLPNH=.TRUE., getmLPSH=.TRUE.)
    call h5close_EMsoft(hdferr)

    ! 3. allocate detector arrays
    allocate(EBSDdetector%rgx(dinl%numsx,dinl%numsy), &
           EBSDdetector%rgy(dinl%numsx,dinl%numsy), &
           EBSDdetector%rgz(dinl%numsx,dinl%numsy), &
           EBSDdetector%accum_e_detector(EBSDMCdata%numEbins,dinl%numsx,dinl%numsy), stat=istat)

    ! 4. copy a few parameters from dinl to enl, which is the regular EBSDNameListType structure
    ! and then generate the detector arrays
    enl%numsx = dinl%numsx
    enl%numsy = dinl%numsy
    enl%xpc = dinl%xpc
    enl%ypc = dinl%ypc
    enl%delta = dinl%delta
    enl%thetac = dinl%thetac
    enl%L = dinl%L
    enl%energymin = dinl%energymin
    enl%energymax = dinl%energymax
    call GenerateEBSDDetector(enl, mcnl, EBSDMCdata, EBSDdetector, verbose)
else    ! this is a static run using an existing dictionary
! we'll use the same MasterSubroutine so we need to at least allocate the input structures
! even though we will not make use of them in static mode
!  allocate(acc, master) 

end if

! perform the dictionary indexing computations
call MasterSubroutine(dinl, mcnl, mpnl, EBSDMCdata, EBSDMPdata, EBSDdetector, progname, nmldeffile)

end program EMEBSDDI

!--------------------------------------------------------------------------
!
! SUBROUTINE:MasterSubroutine
!
!> @author Saransh Singh, Carnegie Mellon University
!
!> @brief Master subroutine to control dictionary generation, inner products computations, sorting values
!> and indexing of points, all in parallel using OpenCL/openMP
!
!> @param dinl ped indexing namelist pointer
!> @param mcnl Monte Carlo namelist structure 
!> @param mpnl Master PAttern namelist structure 
!> @param EBSDMCdata Monte Carlo data arrays
!> @param EBSDMPdata master pattern data arrays
!> @param EBSDdetector detector arrays
!> @param progname name of the program
!> @param nmldeffile namelist filename
!
!> @date 03/30/15  SS 1.0 original
!> @date 05/05/15 MDG 1.1 removed getenv() call; replaced by global path strings
!> @date 02/07/16 MDG 1.2 added image quality computation
!> @date 02/08/16 MDG 1.3 added confidence index output to HDF5 file
!> @date 02/10/16 MDG 1.4 added average dot product map to HDF5 file
!> @date 02/23/16 MDG 1.5 converted program to CLFortran instead of fortrancl.
!> @date 06/07/16 MDG 1.6 added tmpfile for variable temporary data file name
!> @date 11/14/16 MDG 1.7 added code to read h5 file instead of compute on-the-fly (static mode)
!> @date 07/24/17 MDG 1.8 temporary code to change the mask layout for fast DI tests
!> @date 08/30/17 MDG 1.9 added option to read custom mask from file
!> @date 11/13/17 MDG 2.0 moved OpenCL code from InnerProdGPU routine to main code
!> @date 01/09/18 MDG 2.1 first attempt at OpenMP for pattern pre-processing
!> @date 02/13/18 MDG 2.2 added support for multiple input formats for experimental patterns
!> @date 02/22/18 MDG 2.3 added support for Region-of-Interest (ROI) selection
!> @date 04/04/18 MDG 3.0 revised name list use as well as MC and MP data structures
!--------------------------------------------------------------------------
subroutine MasterSubroutine(dinl, mcnl, mpnl, EBSDMCdata, EBSDMPdata, EBSDdetector, progname, nmldeffile)

use local
use typedefs
use NameListTypedefs
use NameListHandlers
use files
use dictmod
use patternmod
use Lambert
use others
use crystal
use initializersHDF
use gvectors
use filters
use error
use io
use diffraction
use symmetry
use quaternions
use constants
use rotations
use so3
use math
use EBSDmod
use EBSDDImod
use clfortran
use CLsupport
use omp_lib
use HDF5
use h5im
use h5lt
use HDFsupport
use EMh5ebsd
use EBSDiomod
use NameListHDFwriters
use ECPmod, only: GetPointGroup
use Indexingmod
use ISO_C_BINDING
use notifications
use TIFF_f90
use timing

IMPLICIT NONE

type(EBSDIndexingNameListType),INTENT(INOUT)        :: dinl
type(MCCLNameListType),INTENT(INOUT)                :: mcnl
type(EBSDMasterNameListType),INTENT(INOUT)          :: mpnl
type(EBSDMCdataType),INTENT(INOUT)                  :: EBSDMCdata
type(EBSDMPdataType),INTENT(INOUT)                  :: EBSDMPdata
type(EBSDDetectorType),INTENT(INOUT)                :: EBSDdetector
character(fnlen),INTENT(IN)                         :: progname
character(fnlen),INTENT(IN)                         :: nmldeffile

type(unitcell),pointer                              :: cell
type(DynType)                                       :: Dyn
type(gnode)                                         :: rlp
logical                                             :: verbose

integer(c_intptr_t),allocatable, target             :: platform(:)
integer(c_intptr_t),allocatable, target             :: device(:)
integer(c_intptr_t),target                          :: context
integer(c_intptr_t),target                          :: command_queue
integer(c_intptr_t),target                          :: cl_expt,cl_dict
character(len = 50000), target                      :: source
integer(kind=irg), parameter                        :: source_length = 50000
integer(kind=irg), target                           :: source_l
character(len=source_length, KIND=c_char),TARGET    :: csource
type(c_ptr), target                                 :: psource
integer(c_int32_t)                                  :: ierr2, pcnt
integer(c_intptr_t),target                          :: prog
integer(c_intptr_t),target                          :: kernel
integer(c_size_t)                                   :: cnum
character(9),target                                 :: kernelname
character(10, KIND=c_char),target                   :: ckernelname

integer(kind=irg)                                   :: num,ierr,irec,istat, jpar(7), SGnum, nlines
integer(kind=irg),parameter                         :: iunit = 40
integer(kind=irg),parameter                         :: iunitexpt = 41
integer(kind=irg),parameter                         :: iunitdict = 42
character(fnlen)                                    :: info ! info about the GPU
real(kind=dbl),parameter                            :: nAmpere = 6.241D+18   ! Coulomb per second


integer(kind=irg)                                   :: Ne,Nd,L,totnumexpt,numdictsingle,numexptsingle,imght,imgwd,nnk, &
                                                       recordsize, fratio, cratio, fratioE, cratioE, iii, itmpexpt, hdferr,&
                                                       recordsize_correct, patsz, tickstart, tock, npy, sz(3)
integer(kind=8)                                     :: size_in_bytes_dict,size_in_bytes_expt
real(kind=sgl),pointer                              :: dict(:), T0dict(:)
real(kind=sgl),allocatable,TARGET                   :: dict1(:), dict2(:)
!integer(kind=1),allocatable                         :: imageexpt(:),imagedict(:)
real(kind=sgl),allocatable                          :: imageexpt(:),imagedict(:), mask(:,:),masklin(:), exptIQ(:), &
                                                       exptCI(:), exptFit(:), exppatarray(:), tmpexppatarray(:)
real(kind=sgl),allocatable                          :: imageexptflt(:),binned(:,:),imagedictflt(:),imagedictfltflip(:), &
                                                       tmpimageexpt(:), OSMmap(:,:)
real(kind=sgl),allocatable, target                  :: results(:),expt(:),dicttranspose(:),resultarray(:),&
                                                       eulerarray(:,:),eulerarray2(:,:),resultmain(:,:),resulttmp(:,:)
integer(kind=irg),allocatable                       :: acc_array(:,:), ppend(:), ppendE(:) 
integer*4,allocatable                               :: iexptCI(:,:), iexptIQ(:,:)
real(kind=sgl),allocatable                          :: meandict(:),meanexpt(:),wf(:),mLPNH(:,:,:),mLPSH(:,:,:),accum_e_MC(:,:,:)
real(kind=sgl),allocatable                          :: mLPNH_simple(:,:), mLPSH_simple(:,:), eangle(:)
real(kind=sgl),allocatable                          :: EBSDpattern(:,:), FZarray(:,:), dpmap(:), lstore(:,:), pstore(:,:)
real(kind=sgl),allocatable                          :: EBSDpatternintd(:,:), lp(:), cp(:), EBSDpat(:,:)
integer(kind=irg),allocatable                       :: EBSDpatterninteger(:,:), EBSDpatternad(:,:), EBSDpint(:,:)
character(kind=c_char),allocatable                  :: EBSDdictpat(:,:,:)
real(kind=sgl),allocatable                          :: EBSDdictpatflt(:,:)
real(kind=dbl),allocatable                          :: rdata(:,:), fdata(:,:), rrdata(:,:), ffdata(:,:), ksqarray(:,:)
complex(kind=dbl),allocatable                       :: hpmask(:,:)
complex(C_DOUBLE_COMPLEX),allocatable               :: inp(:,:), outp(:,:)
real(kind=dbl)                                      :: w, Jres
integer(kind=irg)                                   :: dims(2)
character(11)                                       :: dstr
character(15)                                       :: tstrb
character(15)                                       :: tstre
character(3)                                        :: vendor
character(fnlen, KIND=c_char),allocatable,TARGET    :: stringarray(:)
character(fnlen)                                    :: groupname, dataset, fname, clname, ename, sourcefile, &
                                                       datagroupname, dictfile
integer(hsize_t)                                    :: expwidth, expheight
integer(hsize_t),allocatable                        :: iPhase(:), iValid(:)
integer(c_size_t),target                            :: slength
integer(c_int)                                      :: numd, nump
type(C_PTR)                                         :: planf, HPplanf, HPplanb
integer(HSIZE_T)                                    :: dims2(2), offset2(2), dims3(3), offset3(3)

integer(kind=irg)                                   :: i,j,ii,jj,kk,ll,mm,pp,qq
integer(kind=irg)                                   :: FZcnt, pgnum, io_int(4), ncubochoric, pc
type(FZpointd),pointer                              :: FZlist, FZtmp
integer(kind=irg),allocatable                       :: indexlist(:),indexarray(:),indexmain(:,:),indextmp(:,:)
real(kind=sgl)                                      :: dmin,voltage,scl,ratio, mi, ma, ratioE, io_real(2), tstart, tmp, &
                                                       totnum_el, vlen, tstop, ttime
real(kind=dbl)                                      :: prefactor
character(fnlen)                                    :: xtalname
integer(kind=irg)                                   :: binx,biny,TID,nthreads,Emin,Emax, iiistart, iiiend, jjend
real(kind=sgl)                                      :: sx,dx,dxm,dy,dym,rhos,x,projweight, dp, mvres, nel, emult
real(kind=sgl)                                      :: dc(3),quat(4),ixy(2),bindx
integer(kind=irg)                                   :: nix,niy,nixp,niyp
real(kind=sgl)                                      :: euler(3)
integer(kind=irg)                                   :: indx
integer(kind=irg)                                   :: correctsize
logical                                             :: f_exists, init, ROIselected 

integer(kind=irg)                                   :: ipar(10)

character(fnlen),ALLOCATABLE                        :: MessageLines(:)
integer(kind=irg)                                   :: NumLines
character(fnlen)                                    :: TitleMessage, exectime
character(100)                                      :: c
character(1000)                                     :: charline

type(HDFobjectStackType),pointer                    :: HDF_head

call timestamp(datestring=dstr, timestring=tstrb)

if (trim(dinl%indexingmode).eq.'static') then
    !
    ! Initialize FORTRAN interface.
    CALL h5open_EMsoft(hdferr)

    ! get the full filename
    dictfile = trim(EMsoft_getEMdatapathname())//trim(dinl%dictfile)
    dictfile = EMsoft_toNativePath(dictfile)

    call Message('-->  '//'Opening HDF5 dictionary file '//trim(dinl%dictfile))
    nullify(HDF_head)

    hdferr =  HDF_openFile(dictfile, HDF_head)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_openFile ')

    ! we need the point group number (derived from the space group number)
    groupname = SC_CrystalData
    hdferr = HDF_openGroup(groupname, HDF_head)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_openGroup:CrystalData')

    dataset = SC_SpaceGroupNumber
    call HDF_readDatasetInteger(dataset, HDF_head, hdferr, SGnum)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_readDatasetInteger:SpaceGroupNumber')
    call HDF_pop(HDF_head)
! get the point group number    
    if (SGnum.ge.221) then
      pgnum = 32
    else
      i=0
      do while (SGPG(i+1).le.SGnum) 
        i = i+1
      end do
      pgnum = i
    end if

    ! then read some more data from the EMData group
    groupname = SC_EMData
    hdferr = HDF_openGroup(groupname, HDF_head)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_openGroup:EMData')

    datagroupname = 'EBSD'
    hdferr = HDF_openGroup(datagroupname, HDF_head)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_openGroup:EBSD')

    ! we already have the xtalname string from the Monte Carlo name list
    xtalname = trim(mcnl%xtalname)

    ! number of Eulerangles numangles
    dataset = SC_numangles
    call HDF_readDatasetInteger(dataset, HDF_head, hdferr, FZcnt)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_readDatasetInteger:numangles')

    ! euler angle list Eulerangles
    dataset = SC_Eulerangles
    call HDF_readDatasetFloatArray2D(dataset, dims2, HDF_head, hdferr, eulerarray2)
    eulerarray2 = eulerarray2 * 180.0/sngl(cPi)
    if (hdferr.ne.0) call HDF_handleError(hdferr,'HDF_readDatasetFloatArray2D:Eulerangles')

    ! we leave this file open since we still need to read all the patterns...
    !=====================================================
    call Message('-->  completed initial reading of dictionary file ')
end if

if (sum(dinl%ROI).ne.0) then
  ROIselected = .TRUE.
  iiistart = dinl%ROI(2)
  iiiend = dinl%ROI(2)+dinl%ROI(4)-1
  jjend = dinl%ROI(3)
else
  ROIselected = .FALSE.
  iiistart = 1
  iiiend = dinl%ipf_ht
  jjend = dinl%ipf_wd
end if

verbose = .FALSE.
init = .TRUE.
Ne = dinl%numexptsingle
Nd = dinl%numdictsingle
L = dinl%numsx*dinl%numsy/dinl%binning**2
if (ROIselected.eqv..TRUE.) then 
    totnumexpt = dinl%ROI(3)*dinl%ROI(4)
else
    totnumexpt = dinl%ipf_wd*dinl%ipf_ht
end if
imght = dinl%numsx/dinl%binning
imgwd = dinl%numsy/dinl%binning
dims = (/imght, imgwd/)
nnk = dinl%nnk
ncubochoric = dinl%ncubochoric
recordsize = L*4
itmpexpt = 43
w = dinl%hipassw
source_l = source_length

! these will eventually need to be read from an experimental data file but we'll set defaults values here.
dinl%WD = 10.0

! nullify the dict and T0dict pointers
nullify(dict,T0dict)

! make sure that correctsize is a multiple of 16; if not, make it so
if (mod(L,16) .ne. 0) then
    correctsize = 16*ceiling(float(L)/16.0)
else
    correctsize = L
end if

! determine the experimental and dictionary sizes in bytes
size_in_bytes_dict = Nd*correctsize*sizeof(correctsize)
size_in_bytes_expt = Ne*correctsize*sizeof(correctsize)
recordsize_correct = correctsize*4
patsz              = correctsize


if (trim(dinl%indexingmode).eq.'dynamic') then 
    !=====================================================
    ! EXTRACT POINT GROUP NUMBER FROM CRYSTAL STRUCTURE FILE 
    !=====================================================
    write (*,*) 'reading from xtalfile '//trim(mcnl%xtalname)
    pgnum = GetPointGroup(mcnl%xtalname)

    !=====================================================
    ! make sure the minimum energy is set smaller than the maximum
    !=====================================================
    if (dinl%energymin.gt.dinl%energymax) then
        call Message('Minimum energy is larger than maximum energy; please correct input file')
        stop
    end if

    !=====================================================
    ! get the indices of the minimum and maximum energy
    !=====================================================
    Emin = nint((dinl%energymin - mcnl%Ehistmin)/mcnl%Ebinsize) +1
    if (Emin.lt.1)  Emin=1
    if (Emin.gt.EBSDMCdata%numEbins)  Emin=EBSDMCdata%numEbins

    Emax = nint((dinl%energymax - mcnl%Ehistmin)/mcnl%Ebinsize) + 1
    if (Emax .lt. 1) Emax = 1
    if (Emax .gt. EBSDMCdata%numEbins) Emax = EBSDMCdata%numEbins

    sz = shape(EBSDMPdata%mLPNH)
    dinl%nE = sz(3)

    ! intensity prefactor
    nel = float(mcnl%totnum_el) * float(EBSDMCdata%multiplier)
    emult = nAmpere * 1e-9 / nel  ! multiplicative factor to convert MC data to an equivalent incident beam of 1 nanoCoulomb
    ! intensity prefactor  (redefined by MDG, 3/23/18)
    prefactor = emult * dinl%beamcurrent * dinl%dwelltime * 1.0D-6
end if

!====================================
! init a bunch of parameters
!====================================
! binned pattern array
binx = dinl%numsx/dinl%binning
biny = dinl%numsy/dinl%binning
bindx = 1.0/float(dinl%binning)**2

! for dictionary computations, the patterns are usually rather small, so perhaps the explicit
! energy sums can be replaced by an averaged approximate approach, in which all the energy bins
! are added together from the start, and all the master patterns are totaled as well...
! this is a straightforward sum; we should probably do a weighted sum instead

! this code will be removed in a later version [post 3.1]
npy = mpnl%npx
if (trim(dinl%indexingmode).eq.'dynamic') then
    if (dinl%energyaverage .eq. 0) then
            allocate(mLPNH(-mpnl%npx:mpnl%npx,-npy:npy,EBSDMCdata%numEbins))
            allocate(mLPSH(-mpnl%npx:mpnl%npx,-npy:npy,EBSDMCdata%numEbins))
            allocate(accum_e_MC(EBSDMCdata%numEbins,dinl%numsx,dinl%numsy),stat=istat)
            accum_e_MC = EBSDdetector%accum_e_detector
            mLPNH = EBSDMPdata%mLPNH
            mLPSH = EBSDMPdata%mLPSH
    else if (dinl%energyaverage .eq. 1) then
            allocate(mLPNH_simple(-mpnl%npx:mpnl%npx,-npy:npy))
            allocate(mLPSH_simple(-mpnl%npx:mpnl%npx,-npy:npy))
            allocate(wf(EBSDMCdata%numEbins))
            allocate(acc_array(dinl%numsx,dinl%numsy))
            acc_array = sum(EBSDdetector%accum_e_detector,1)
            wf = sum(sum(EBSDdetector%accum_e_detector,2),2)
            wf = wf/sum(wf)
            do ii=Emin,Emax
                EBSDMPdata%mLPNH(-mpnl%npx:mpnl%npx,-npy:npy,ii) = &
                EBSDMPdata%mLPNH(-mpnl%npx:mpnl%npx,-npy:npy,ii) * wf(ii)

                EBSDMPdata%mLPSH(-mpnl%npx:mpnl%npx,-npy:npy,ii) = &
                EBSDMPdata%mLPSH(-mpnl%npx:mpnl%npx,-npy:npy,ii) * wf(ii)

            end do
            mLPNH_simple = sum(EBSDMPdata%mLPNH,3)
            mLPSH_simple = sum(EBSDMPdata%mLPNH,3)
    else
            stop 'Invalid value of energyaverage parameter'
    end if
end if

!=====================================================
! SAMPLING OF RODRIGUES FUNDAMENTAL ZONE
!=====================================================
! if eulerfile is not defined, then we use the standard RFZ sampling;
! if it is defined, then we read the Eulerangle triplets from the file
! and generate the FZlist here... this can be useful to index patterns that
! have only a small misorientation range with respect to a known orientation,
! so that it is not necessary to scan all of orientation space.
if (trim(dinl%indexingmode).eq.'dynamic') then
    nullify(FZlist)
    FZcnt = 0
    if (trim(dinl%eulerfile).eq.'undefined') then
      call Message('Orientation space sampling mode set to RFZ')
      io_int(1) = pgnum
      io_int(2) = ncubochoric
      call WriteValue('Point group number and number of cubochoric sampling points : ',io_int,2,"(I4,',',I5)")

      call sampleRFZ(ncubochoric, pgnum, 0, FZcnt, FZlist)
    else
    ! read the euler angle file and create the linked list
      call getEulersfromFile(dinl%eulerfile, FZcnt, FZlist) 
      call Message('Orientation space sampling mode set to MIS')
      io_int(1) = pgnum
      io_int(2) = FZcnt
      call WriteValue('Point group number and number of sampling points : ',io_int,2,"(I4,',',I5)")
    end if

    ! allocate and fill FZarray for OpenMP parallelization
    allocate(FZarray(4,FZcnt),stat=istat)
    FZarray = 0.0

    FZtmp => FZlist
    do ii = 1,FZcnt
        FZarray(1:4,ii) = FZtmp%rod(1:4)
        FZtmp => FZtmp%next
    end do
    io_int(1) = FZcnt
    call WriteValue(' Number of unique orientations sampled =        : ', io_int, 1, "(I8)")
end if 


!================================
! INITIALIZATION OF OpenCL DEVICE
!================================
call Message('--> Initializing OpenCL device')

call CLinit_PDCCQ(platform, nump, dinl%platid, device, numd, dinl%devid, info, context, command_queue)

! read the cl source file
sourcefile = 'DictIndx.cl'
call CLread_source_file(sourcefile, csource, slength)

! allocate device memory for experimental and dictionary patterns
cl_expt = clCreateBuffer(context, CL_MEM_READ_WRITE, size_in_bytes_expt, C_NULL_PTR, ierr)
call CLerror_check('MasterSubroutine:clCreateBuffer', ierr)

cl_dict = clCreateBuffer(context, CL_MEM_READ_WRITE, size_in_bytes_dict, C_NULL_PTR, ierr)
call CLerror_check('MasterSubroutine:clCreateBuffer', ierr)

!================================
! the following lines were originally in the InnerProdGPU routine, but there is no need
! to execute them each time that routine is called so we move them here...
!================================
! create the program
pcnt = 1
psource = C_LOC(csource)
!prog = clCreateProgramWithSource(context, pcnt, C_LOC(psource), C_LOC(source_l), ierr)
prog = clCreateProgramWithSource(context, pcnt, C_LOC(psource), C_LOC(slength), ierr)
call CLerror_check('InnerProdGPU:clCreateProgramWithSource', ierr)

! build the program
ierr = clBuildProgram(prog, numd, C_LOC(device), C_NULL_PTR, C_NULL_FUNPTR, C_NULL_PTR)

! get the compilation log
ierr2 = clGetProgramBuildInfo(prog, device(dinl%devid), CL_PROGRAM_BUILD_LOG, sizeof(source), C_LOC(source), cnum)
! if(cnum > 1) call Message(trim(source(1:cnum))//'test',frm='(A)')
call CLerror_check('InnerProdGPU:clBuildProgram', ierr)
call CLerror_check('InnerProdGPU:clGetProgramBuildInfo', ierr2)

! finally get the kernel and release the program
kernelname = 'InnerProd'
ckernelname = kernelname
ckernelname(10:10) = C_NULL_CHAR
kernel = clCreateKernel(prog, C_LOC(ckernelname), ierr)
call CLerror_check('InnerProdGPU:clCreateKernel', ierr)

ierr = clReleaseProgram(prog)
call CLerror_check('InnerProdGPU:clReleaseProgram', ierr)

! the remainder is done in the InnerProdGPU routine
!=========================================

!=========================================
! ALLOCATION AND INITIALIZATION OF ARRAYS
!=========================================
call Message('--> Allocating various arrays for indexing')

allocate(expt(Ne*correctsize),stat=istat)
if (istat .ne. 0) stop 'Could not allocate array for experimental patterns'
expt = 0.0

allocate(dict1(Nd*correctsize),dict2(Nd*correctsize),dicttranspose(Nd*correctsize),stat=istat)
if (istat .ne. 0) stop 'Could not allocate array for dictionary patterns'
dict1 = 0.0
dict2 = 0.0
dict => dict1
dicttranspose = 0.0

allocate(results(Ne*Nd),stat=istat)
if (istat .ne. 0) stop 'Could not allocate array for results'
results = 0.0

allocate(mask(binx,biny),masklin(L),stat=istat)
if (istat .ne. 0) stop 'Could not allocate arrays for masks'
mask = 1.0
masklin = 0.0

allocate(imageexpt(L),imageexptflt(correctsize),imagedictflt(correctsize),imagedictfltflip(correctsize),stat=istat)
allocate(tmpimageexpt(correctsize),stat=istat)
if (istat .ne. 0) stop 'Could not allocate array for reading experimental image patterns'
imageexpt = 0.0
imageexptflt = 0.0

allocate(meandict(correctsize),meanexpt(correctsize),imagedict(correctsize),stat=istat)
if (istat .ne. 0) stop 'Could not allocate array for mean dictionary and experimental patterns'
meandict = 0.0
meanexpt = 0.0

! allocate(EBSDpattern(dinl%numsx,dinl%numsy),binned(binx,biny),stat=istat)
allocate(EBSDpattern(binx,biny),binned(binx,biny),stat=istat)
if (istat .ne. 0) stop 'Could not allocate array for EBSD pattern'
EBSDpattern = 0.0
binned = 0.0

allocate(resultarray(1:Nd),stat=istat)
if (istat .ne. 0) stop 'could not allocate result arrays'

resultarray = 0.0

allocate(indexarray(1:Nd),stat=istat)
if (istat .ne. 0) stop 'could not allocate index arrays'

indexarray = 0

allocate(indexlist(1:Nd*(ceiling(float(FZcnt)/float(Nd)))),stat=istat)
if (istat .ne. 0) stop 'could not allocate indexlist arrays'

indexlist = 0

do ii = 1,Nd*ceiling(float(FZcnt)/float(Nd))
    indexlist(ii) = ii
end do

allocate(resultmain(nnk,Ne*ceiling(float(totnumexpt)/float(Ne))),stat=istat)
if (istat .ne. 0) stop 'could not allocate main result array'

resultmain = -2.0

allocate(indexmain(nnk,Ne*ceiling(float(totnumexpt)/float(Ne))),stat=istat)
if (istat .ne. 0) stop 'could not allocate main index array'

indexmain = 0

allocate(resulttmp(2*nnk,Ne*ceiling(float(totnumexpt)/float(Ne))),stat=istat)
if (istat .ne. 0) stop 'could not allocate temporary result array'

resulttmp = -2.0

allocate(indextmp(2*nnk,Ne*ceiling(float(totnumexpt)/float(Ne))),stat=istat)
if (istat .ne. 0) stop 'could not allocate temporary index array'

indextmp = 0

allocate(eulerarray(1:3,Nd*ceiling(float(FZcnt)/float(Nd))),stat=istat)
if (istat .ne. 0) stop 'could not allocate euler array'
eulerarray = 0.0
if (trim(dinl%indexingmode).eq.'static') then
    eulerarray(1:3,1:FZcnt) = eulerarray2(1:3,1:FZcnt)
    deallocate(eulerarray2)
end if

allocate(exptIQ(totnumexpt), exptCI(totnumexpt), exptFit(totnumexpt), stat=istat)
if (istat .ne. 0) stop 'could not allocate exptIQ array'

allocate(rdata(binx,biny),fdata(binx,biny),stat=istat)
if (istat .ne. 0) stop 'could not allocate arrays for Hi-Pass filter'
rdata = 0.D0
fdata = 0.D0

! also, allocate the arrays used to create the average dot product map; this will require 
! reading the actual EBSD HDF5 file to figure out how many rows and columns there
! are in the region of interest.  For now we get those from the nml until we actually 
! implement the HDF5 reading bit
! this portion of code was first tested in IDL.
allocate(EBSDpatterninteger(binx,biny))
EBSDpatterninteger = 0
allocate(EBSDpatternad(binx,biny),EBSDpatternintd(binx,biny))
EBSDpatternad = 0.0
EBSDpatternintd = 0.0

!=====================================================
! determine loop variables to avoid having to duplicate 
! large sections of mostly identical code
!=====================================================
ratio = float(FZcnt)/float(Nd)
cratio = ceiling(ratio)
fratio = floor(ratio)

ratioE = float(totnumexpt)/float(Ne)
cratioE = ceiling(ratioE)
fratioE = floor(ratioE)

allocate(ppend(cratio),ppendE(cratioE))
ppend = (/ (Nd, i=1,cratio) /)
if (fratio.lt.cratio) then
  ppend(cratio) = MODULO(FZcnt,Nd)
end if

ppendE = (/ (Ne, i=1,cratioE) /)
if (fratioE.lt.cratioE) then
  ppendE(cratioE) = MODULO(totnumexpt,Ne)
end if

!=====================================================
! define the circular mask if necessary and convert to 1D vector
!=====================================================

if (trim(dinl%maskfile).ne.'undefined') then
! read the mask from file; the mask can be defined by a 2D array of 0 and 1 values
! that is stored in row form as strings, e.g.    
!    0000001110000000
!    0000011111000000
! ... etc
!
    f_exists = .FALSE.
    fname = trim(EMsoft_getEMdatapathname())//trim(dinl%maskfile)
    fname = EMsoft_toNativePath(fname)
    inquire(file=trim(fname), exist=f_exists)
    if (f_exists.eqv..TRUE.) then
      mask = 0.0
      open(unit=dataunit,file=trim(fname),status='old',form='formatted')
      do jj=biny,1,-1
        read(dataunit,"(A)") charline
        do ii=1,binx
          if (charline(ii:ii).eq.'1') mask(ii,jj) = 1.0
        end do
      end do
      close(unit=dataunit,status='keep')
    else
      call FatalError('MasterSubroutine','maskfile '//trim(fname)//' does not exist')
    end if
else
    if (dinl%maskpattern.eq.'y') then
      do ii = 1,biny
          do jj = 1,binx
              if((ii-biny/2)**2 + (jj-binx/2)**2 .ge. dinl%maskradius**2) then
                  mask(jj,ii) = 0.0
              end if
          end do
      end do
    end if
end if

! convert the mask to a linear (1D) array
do ii = 1,biny
    do jj = 1,binx
        masklin((ii-1)*binx+jj) = mask(jj,ii)
    end do
end do

!=====================================================
! Preprocess all the experimental patterns and store
! them in a temporary file as vectors; also, create 
! an average dot product map to be stored in the h5ebsd output file
!=====================================================
call h5open_EMsoft(hdferr)
call PreProcessPatterns(dinl%nthreads, .FALSE., dinl, binx, biny, masklin, correctsize, totnumexpt, exptIQ=exptIQ)
call h5close_EMsoft(hdferr)

!=====================================================
call Message(' -> computing Average Dot Product map (ADP)')
call Message(' ')

! re-open the temporary file
fname = trim(EMsoft_getEMtmppathname())//trim(dinl%tmpfile)
fname = EMsoft_toNativePath(fname)

open(unit=itmpexpt,file=trim(fname),&
     status='old',form='unformatted',access='direct',recl=recordsize_correct,iostat=ierr)

! use the getADPmap routine in the filters module
if (ROIselected.eqv..TRUE.) then
  allocate(dpmap(dinl%ROI(3)*dinl%ROI(4)))
  call getADPmap(itmpexpt, dinl%ROI(3)*dinl%ROI(4), L, dinl%ROI(3), dinl%ROI(4), dpmap)
  TIFF_nx = dinl%ROI(3)
  TIFF_ny = dinl%ROI(4)
else
  allocate(dpmap(totnumexpt))
  call getADPmap(itmpexpt, totnumexpt, L, dinl%ipf_wd, dinl%ipf_ht, dpmap)
  TIFF_nx = dinl%ipf_wd
  TIFF_ny = dinl%ipf_ht
end if

! we will leave the itmpexpt file open, since we'll be reading from it again...

!=====================================================
! MAIN COMPUTATIONAL LOOP
!
! Some explanation is necessary here... the bulk of this code is 
! executed in OpenMP multithreaded mode, with nthreads threads.
! Thread 0 has a special role described below; threads 1 ... nthreads-1
! share the computation of the dictionary patterns, and wait for 
! thread 0 to finish, if necessary.
!
! Thread 0 takes the dictionary patterns computed by the other threads
! in the previous step in the dictionaryloop and sends them to the GPU,
! along with as many chunks of experimental data are to be handled (experimentalloop
! inside the thread 0 portion of the code); the experimental patterns 
! are then read from the temporary file (unit itmpexpt).  Once all dot
! products have been computed by the GPU, thread 0 will rank them largest
! to smallest and keep only the top nnk values along with their indices 
! into the array of Euler angle triplets.  If the other threads are still
! computing dictionary patterns, thread 0 will join them; otherwise
! thread 0 will immediately take the next batch of dictionary patterns 
! and start all over.
!
! The trick is for the user to determine the array chunk sizes so that 
! threads 1 ... nthreads-1 do not have to wait for thread 0 to finish;
! this requires a bit of experimenting and observing the load on all the 
! system cores.  The load should always be approximately 100% x nthreads-1
! for an efficient execution.  The appropriate number of threads will depend
! on how powerful the GPU card is...
!=====================================================

call cpu_time(tstart)
call Time_tick(tickstart)

if (trim(dinl%indexingmode).eq.'dynamic') then
    call OMP_SET_NUM_THREADS(dinl%nthreads)
    io_int(1) = dinl%nthreads
else
    call OMP_SET_NUM_THREADS(2)
    io_int(1) = 2
end if
call WriteValue(' -> Number of threads set to ',io_int,1,"(I3)")

! define the jpar array of integer parameters
jpar(1) = dinl%binning
jpar(2) = dinl%numsx
jpar(3) = dinl%numsy
jpar(4) = mpnl%npx
jpar(5) = npy
jpar(6) = EBSDMCdata%numEbins
jpar(7) = dinl%nE

call timestamp()

dictionaryloop: do ii = 1,cratio+1
    results = 0.0

! if ii is odd, then we use dict1 for the dictionary computation, and dict2 for the GPU
! (assuming ii>1); when ii is even we switch the two pointers 
    if (mod(ii,2).eq.1) then
      dict => dict1
      dict1 = 0.0
      T0dict => dict2   ! these are the patterns to be sent to the GPU
      if (verbose.eqv..TRUE.) call WriteValue('','dict => dict1; T0dict => dict2')
    else
      dict => dict2
      dict2 = 0.0
      T0dict => dict1   ! these are the patterns to be sent to the GPU
      if (verbose.eqv..TRUE.) call WriteValue('','dict => dict2; T0dict => dict1')
    end if

    if (verbose.eqv..TRUE.) then
      io_int(1) = ii
      call WriteValue('Dictionaryloop index = ',io_int,1)
    end if

!$OMP PARALLEL DEFAULT(SHARED) PRIVATE(TID,iii,jj,ll,mm,pp,ierr,io_int, tock, ttime) &
!$OMP& PRIVATE(binned, ma, mi, EBSDpatternintd, EBSDpatterninteger, EBSDpatternad, quat, imagedictflt,imagedictfltflip)

        TID = OMP_GET_THREAD_NUM()

      if ((ii.eq.1).and.(TID.eq.0)) write(*,*) ' actual number of OpenMP threads  = ',OMP_GET_NUM_THREADS()

! the master thread should be the one working on the GPU computation
!$OMP MASTER
    if (ii.gt.1) then
      iii = ii-1        ! the index ii is already one ahead, since the GPU thread lags one cycle behind the others...
      if (verbose.eqv..TRUE.) then 
        if (associated(T0dict,dict1)) then 
          write(*,"('   GPU thread is working on dict1')")
        else
          write(*,"('   GPU thread is working on dict2')")
        end if
      end if

      dicttranspose = 0.0

      do ll = 1,correctsize
        do mm = 1,Nd
            dicttranspose((ll-1)*Nd+mm) = T0dict((mm-1)*correctsize+ll)
        end do
      end do

      ierr = clEnqueueWriteBuffer(command_queue, cl_dict, CL_TRUE, 0_8, size_in_bytes_dict, C_LOC(dicttranspose(1)), &
                                  0, C_NULL_PTR, C_NULL_PTR)
      call CLerror_check('MasterSubroutine:clEnqueueWriteBuffer', ierr)

      mvres = 0.0

      experimentalloop: do jj = 1,cratioE

        expt = 0.0

        do pp = 1,ppendE(jj)   ! Ne or MODULO(totnumexpt,Ne)
          read(itmpexpt,rec=(jj-1)*Ne+pp) tmpimageexpt
          expt((pp-1)*correctsize+1:pp*correctsize) = tmpimageexpt
        end do

        ierr = clEnqueueWriteBuffer(command_queue, cl_expt, CL_TRUE, 0_8, size_in_bytes_expt, C_LOC(expt(1)), &
                                    0, C_NULL_PTR, C_NULL_PTR)
        call CLerror_check('MasterSubroutine:clEnqueueWriteBuffer', ierr)

        call InnerProdGPU(cl_expt,cl_dict,Ne,Nd,correctsize,results,numd,dinl%devid,kernel,context,command_queue)

        dp =  maxval(results)
        if (dp.gt.mvres) mvres = dp

! this might be simplified later for the remainder of the patterns
        do qq = 1,ppendE(jj)
            resultarray(1:Nd) = results((qq-1)*Nd+1:qq*Nd)
            indexarray(1:Nd) = indexlist((iii-1)*Nd+1:iii*Nd)

            call SSORT(resultarray,indexarray,Nd,-2)
            resulttmp(nnk+1:2*nnk,(jj-1)*Ne+qq) = resultarray(1:nnk)
            indextmp(nnk+1:2*nnk,(jj-1)*Ne+qq) = indexarray(1:nnk)

            call SSORT(resulttmp(:,(jj-1)*Ne+qq),indextmp(:,(jj-1)*Ne+qq),2*nnk,-2)

            resultmain(1:nnk,(jj-1)*Ne+qq) = resulttmp(1:nnk,(jj-1)*Ne+qq)
            indexmain(1:nnk,(jj-1)*Ne+qq) = indextmp(1:nnk,(jj-1)*Ne+qq)
        end do
      end do experimentalloop

      io_real(1) = mvres
      io_real(2) = float(iii)/float(cratio)*100.0
      call WriteValue('',io_real,2,"(' max. dot product = ',F10.6,';',F6.1,'% complete')")


      if (mod(iii,10) .eq. 0) then
! do a remaining time estimate
! and print information
        if (iii.eq.10) then
            tock = Time_tock(tickstart)
            ttime = float(tock) * float(cratio) / float(iii)
            tstop = ttime
            io_int(1:4) = (/iii,cratio, int(ttime/3600.0), int(mod(ttime,3600.0)/60.0)/)
            call WriteValue('',io_int,4,"(' -> Completed cycle ',I5,' out of ',I5,'; est. total time ', &
                           I4,' hrs',I3,' min')")
        else
            ttime = tstop * float(cratio-iii) / float(cratio)
            io_int(1:4) = (/iii,cratio, int(ttime/3600.0), int(mod(ttime,3600.0)/60.0)/)
            call WriteValue('',io_int,4,"(' -> Completed cycle ',I5,' out of ',I5,'; est. remaining time ', &
                           I4,' hrs',I3,' min')")
        end if
      end if
    else
       if (verbose.eqv..TRUE.) call WriteValue('','        GPU thread is idling')
    end if  ! ii.gt.1

!$OMP END MASTER


! here we carry out the dictionary pattern computation, unless we are in the ii=cratio+1 step
    if (ii.lt.cratio+1) then
     if (verbose.eqv..TRUE.) then
       if (associated(dict,dict1)) then 
         write(*,"('    Thread ',I2,' is working on dict1')") TID
       else
         write(*,"('    Thread ',I2,' is working on dict2')") TID
       end if
     end if

if (trim(dinl%indexingmode).eq.'dynamic') then
!$OMP DO SCHEDULE(DYNAMIC)

     do pp = 1,ppend(ii)  !Nd or MODULO(FZcnt,Nd)
       binned = 0.0
       quat = ro2qu(FZarray(1:4,(ii-1)*Nd+pp))

       if (dinl%energyaverage .eq. 0) then
         call CalcEBSDPatternSingleFull(jpar,quat,accum_e_MC,mLPNH,mLPSH,EBSDdetector%rgx,&
                                        EBSDdetector%rgy,EBSDdetector%rgz,binned,Emin,Emax,mask,prefactor)
       else if (dinl%energyaverage .eq. 1) then 
         call CalcEBSDPatternSingleApprox(jpar,quat,acc_array,mLPNH_simple,mLPSH_simple,EBSDdetector%rgx,&
                                                   EBSDdetector%rgy,EBSDdetector%rgz,binned,mask,prefactor)
       else
         stop 'Invalid value of energyaverage'
       end if

       if (dinl%scalingmode .eq. 'gam') then
         binned = binned**dinl%gammavalue
       end if

! hi pass filtering
!      rdata = dble(binned)
!      fdata = HiPassFilter(rdata,dims,w)
!      binned = sngl(fdata)


! adaptive histogram equalization
       ma = maxval(binned)
       mi = minval(binned)
       
       EBSDpatternintd = ((binned - mi)/ (ma-mi))
       EBSDpatterninteger = nint(EBSDpatternintd*255.0)
       EBSDpatternad =  adhisteq(dinl%nregions,binx,biny,EBSDpatterninteger)
       binned = float(EBSDpatternad)

       imagedictflt = 0.0
       imagedictfltflip = 0.0
       do ll = 1,biny
         do mm = 1,binx
           imagedictflt((ll-1)*binx+mm) = binned(mm,ll)
         end do
       end do

! normalize and apply circular mask 
       imagedictflt(1:L) = imagedictflt(1:L) * masklin(1:L)
       vlen = NORM2(imagedictflt(1:correctsize))
       if (vlen.ne.0.0) then
         imagedictflt(1:correctsize) = imagedictflt(1:correctsize)/vlen
       else
         imagedictflt(1:correctsize) = 0.0
       end if
       
       dict((pp-1)*correctsize+1:pp*correctsize) = imagedictflt(1:correctsize)

       eulerarray(1:3,(ii-1)*Nd+pp) = 180.0/cPi*ro2eu(FZarray(1:4,(ii-1)*Nd+pp))
     end do
!$OMP END DO

else  ! we are doing static indexing, so only 2 threads in total

! get a set of patterns from the precomputed dictionary file... 
! we'll use a hyperslab to read a block of preprocessed patterns from file 

   if (TID .ne. 0) then
! read data from the hyperslab
     dataset = SC_EBSDpatterns
     dims2 = (/ correctsize, ppend(ii) /)
     offset2 = (/ 0, (ii-1)*Nd /)

     if(allocated(EBSDdictpatflt)) deallocate(EBSDdictpatflt)
     EBSDdictpatflt = HDF_readHyperslabFloatArray2D(dataset, offset2, dims2, HDF_head)
      
     do pp = 1,ppend(ii)  !Nd or MODULO(FZcnt,Nd)
       dict((pp-1)*correctsize+1:pp*correctsize) = EBSDdictpatflt(1:correctsize,pp)
     end do
   end if   

end if

     if (verbose.eqv..TRUE.) then
       io_int(1) = TID
       call WriteValue('',io_int,1,"('       Thread ',I2,' is done')")
     end if
   else
     if (verbose.eqv..TRUE.) then
       io_int(1) = TID
       call WriteValue('',io_int,1,"('       Thread ',I2,' idling')")
     end if
   end if

! and we end the parallel section here (all threads will synchronize).
!$OMP END PARALLEL

end do dictionaryloop

if (dinl%keeptmpfile.eq.'n') then
    close(itmpexpt,status='delete')
else
    close(itmpexpt,status='keep')
end if

! release the OpenCL kernel
ierr = clReleaseKernel(kernel)
call CLerror_check('InnerProdGPU:clReleaseKernel', ierr)

if (trim(dinl%indexingmode).eq.'static') then
! close file and nullify pointer
    call HDF_pop(HDF_head,.TRUE.)
    call h5close_EMsoft(hdferr)
end if

! perform some timing stuff
call CPU_TIME(tstop)
tstop = tstop - tstart
io_real(1) = float(totnumexpt)*float(FZcnt) / tstop
call WriteValue('Number of pattern comparisons per second : ',io_real,1,"(/,F10.2)")
io_real(1) = float(totnumexpt) / tstop
call WriteValue('Number of experimental patterns indexed per second : ',io_real,1,"(/,F10.2,/)")

! ===================
! MAIN OUTPUT SECTION
! ===================

! fill the ipar array with integer parameters that are needed to write the h5ebsd file
! (anything other than what is already in the dinl structure)
ipar = 0
ipar(1) = nnk
ipar(2) = Ne*ceiling(float(totnumexpt)/float(Ne))
ipar(3) = totnumexpt
ipar(4) = Nd*ceiling(float(FZcnt)/float(Nd))
ipar(5) = FZcnt
ipar(6) = pgnum
if (ROIselected.eqv..TRUE.) then
  ipar(7) = dinl%ROI(3)
  ipar(8) = dinl%ROI(4)
else
  ipar(7) = dinl%ipf_wd
  ipar(8) = dinl%ipf_ht
end if 

allocate(OSMmap(jjend, iiiend))

! Initialize FORTRAN interface.
call h5open_EMsoft(hdferr)

if (dinl%datafile.ne.'undefined') then 
  vendor = 'TSL'
  call h5ebsd_writeFile(vendor, dinl, mcnl%xtalname, dstr, tstrb, ipar, resultmain, exptIQ, indexmain, eulerarray, &
                        dpmap, progname, nmldeffile, OSMmap)
  call Message('Data stored in h5ebsd file : '//trim(dinl%datafile))
end if

if (dinl%ctffile.ne.'undefined') then 
  call ctfebsd_writeFile(dinl,mcnl%xtalname,ipar,indexmain,eulerarray,resultmain, OSMmap, exptIQ)
  call Message('Data stored in ctf file : '//trim(dinl%ctffile))
end if

if (dinl%angfile.ne.'undefined') then 
  write (*,*) 'ang format not available until Release 4.2'
  !call angebsd_writeFile(dinl,ipar,indexmain,eulerarray,resultmain)
  !call Message('Data stored in ang file : '//trim(dinl%angfile))
end if

! close the fortran HDF5 interface
call h5close_EMsoft(hdferr)

! if requested, we notify the user that this program has completed its run
if (trim(EMsoft_getNotify()).ne.'Off') then
  if (trim(dinl%Notify).eq.'On') then 
    NumLines = 3
    allocate(MessageLines(NumLines))

    call hostnm(c)
 
    MessageLines(1) = 'EMEBSDDI program has ended successfully'
    MessageLines(2) = 'Indexed data stored in '//trim(dinl%datafile)
    write (exectime,"(F15.0)") tstop  
    MessageLines(3) = 'Total execution time [s]: '//trim(exectime)
    TitleMessage = 'EMsoft on '//trim(c)
    i = PostMessage(MessageLines, NumLines, TitleMessage)
  end if
end if


end subroutine MasterSubroutine
