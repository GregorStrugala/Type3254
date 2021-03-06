﻿! +---------------------------------------------------------+
! | TRNSYS Type3223: Variable capacity heat pump controller |
! +---------------------------------------------------------+

! This routine implements a controller for an air-source heat pump with variable speed compressor.


! Inputs
! --------------------------------------------------------------------------------------------------
!  # | Variable     | Description                                   | Input Units   | Internal Units
! --------------------------------------------------------------------------------------------------
!  1 | onOff        | ON/OFF signal                                 | -             | -
!  2 | Tset         | Setpoint temperature                          | °C            | °C
!  3 | AFRlevel     | Level of the unit air flow rate / fan speed   | -             | -
!  4 | Tr           | Return temperature (controlled variable)      | °C            | °C
!  5 | Toa          | Outdoor air temperature                       | °C            | °C
!  6 | fmin         | Minimum value for the output frequency        | -             | -
!  7 | fmax         | Maximum value for the output frequency        | -             | -
!  8 | mode         | 0 = cooling mode                              | -             | -
!                   | 1 = heating mode                              |               |
!  9 | defrost_mode |-1 = defrost cycles (normal behaviour)         | -             | -
!                   | 0 = defrost (off) mode                        |               |
!                   | 1 = recovery mode (transient)                 |               |
!                   | 2 = steady-state mode                         |               |
! 10 | N            | Number of frequency levels                    | -             | -
! 11 | Kc           | Gain constant                                 | -             | -
! 12 | ti           | Integral time constant                        | h             | h
! 13 | tt           | Tracking time constant                        | h             | h
! 14 | b            | Proportional setpoint weight                  | -             | -
! --------------------------------------------------------------------------------------------------

! Parameters
! --------------------------------------------------------------------------------------------------
! # | Variable      | Description                                   | Param. Units  | Internal Units
! --------------------------------------------------------------------------------------------------
! 1 | mode_deadband | Operating mode deadband for automatic mode    | °C            | °C
! 2 | t_fm_min      | Minimum fixed operating mode duration         | min           | h
! 3 | t_mnt_min     | Minimum forced monotonous frequency duration  | min           | h
! 4 | nIterMax      | Maximum number of iterations                  | -             | -
! 5 | LUcool        | Logical Unit - cooling mode                   | -             | -
! 6 | LUheat        | Logical Unit - heating mode                   | -             | -
! --------------------------------------------------------------------------------------------------

! Outputs
! --------------------------------------------------------------------------------------------------
!  # | Variable     | Description                                   | Output  Units | Internal Units
! --------------------------------------------------------------------------------------------------
!  1 | fq           | Normalized frequency (control signal)         | -             | -
!  2 | AFR          | Normalized air flow rate / fan speed ratio    | -             | -
!  3 | mode         | 0 = cooling mode                              | -             | -
!                   | 1 = heating mode                              |               |
!  4 | defrost_mode | 0 = defrost (off) mode                        | -             | -
!                   | 1 = recovery mode (transient)                 |               |
!                   | 2 = steady-state mode                         |               |
!  5 | recov_penalty| capacity penalty factor for recovery mode     | -             | -
! --------------------------------------------------------------------------------------------------

! Author: Gregor Strugala

module Type3223Data

! Defines a constant "wp" (working precision) that can be used in real numbers,
! e.g. 1.0_wp, and sets it to real64 (double precision)
use, intrinsic :: iso_fortran_env, only : wp=>real64
implicit none

type Type3223DataStruct

    ! Frequency limitation parameters
    real(wp) :: e_min(0:1), e_max(0:1)
    integer :: nAFR(0:1), nAFRboost(0:1), nf0(0:1), nZones, nAFR2
    real(wp), allocatable :: AFR(:, :), AFRerror(:, :), AFRdb(:, :)
    real(wp), allocatable :: f0(:, :), Toa0(:, :)
    real(wp), allocatable :: f2(:, :), AFR2(:), Toa2(:), db2(:)
    real(wp) :: f2heat, t_boost_max, f1f2

    ! Defrost parameters
    real(wp) :: Tcutoff, t_df, t_h(4), t_rec(2), Tmin

end type Type3223DataStruct

type(Type3223DataStruct), allocatable, save :: s(:)

end module Type3223Data

subroutine Type3223
!export this subroutine for its use in external DLLs
!dec$attributes dllexport :: Type3223

use, intrinsic :: iso_fortran_env, only : wp=>real64

use TrnsysConstants
use TrnsysFunctions
use Type3223Data

implicit none

integer :: thisUnit, thisType  ! unit and type numbers
real(wp) :: time, dt  ! TRNSYS time and timestep

real(wp) :: Tset, Tr, Toa ! Temperatures
real(wp) :: fsat, fq, fmin, fmax  ! Frequencies
real(wp) :: onOff, Kc, ti, tt, b  ! Controller parameters
real(wp) :: e, es, f, fp, fi  ! Controller signals
real(wp) :: Tset_old, Tr_old, fi_old, es_old, e_old  ! Values of the previous timestep
real(wp) :: mode_deadband, t_fm_min  ! Parameters
real(wp) :: t_fm  ! time in fixed mode operation
real(wp) :: fqLastTimestep, fqLastIteration, t_mnt_min, t_mnt  ! time during wich the frequency must stay monotonic
integer :: dfdt_sign, dfdt_sign_prev  ! sign of the frequency derivative
integer :: LUheat, LUcool, nIterMax  ! Parameters
integer :: N, mode, prev_mode  ! Number of frequency levels, operating mode
integer :: Ni = 1, Ninstances = 1  ! temporary, should use a kernel function to get the actual instance number.
integer :: AFRlevel, old_AFRlevel, zone, old_zone, AFR2level, Toalevel
real(wp) :: AFR, t_boost
logical :: modulate, fmaxBoost
integer :: defrost_mode, nIter
real(wp) :: t_ld, t_uc, t_oc, Toa_av, Toa_av_prev, t_rec, recov_penalty


! Set the version number for this Type
if ( GetIsVersionSigningTime() ) then
    call SetTypeVersion(18)
    return
endif

time = GetSimulationTime()
dt = GetSimulationTimeStep()
thisUnit = GetCurrentUnit()
thisType = GetCurrentType()

! All the stuff that must be done once at the beginning
if ( GetIsFirstCallofSimulation() ) then
    call ExecuteFirstCallOfSimulation()
    return
endif

! Parameters must be re-read - indicates another unit of this Type
if ( GetIsReReadParameters() ) call ReadParameters()

! Start of the first timestep: no iterations, outputs initial conditions
if ( GetIsStartTime() ) then
    call ExecuteStartTime()
    return
endif

! End of timestep call (after convergence or too many iterations)
if ( GetIsEndOfTimestep() ) then
    call ExecuteEndOfTimestep()
    return
endif

if ( GetIsLastCallofSimulation() ) then
    call ExecuteLastCallOfSimulation()
    return
endif

call GetInputValues()
if (ErrorFound()) return

e = Tset - Tr  ! control error
if (mode == -1) then  ! automatic setting of the operating mode
    prev_mode = int(GetDynamicArrayValueLastTimestep(4))  ! mode at the last timestep
    t_fm = GetDynamicArrayValueLastTimestep(15)  ! fixed mode operation timer
    if (t_fm <= t_fm_min) then  ! fixed operating mode duration under minimum time
        mode = prev_mode  ! keep the same mode
        t_fm = t_fm + dt  ! increment the timer
    else
        ! Use a deadband to avoid oscillations. Inside the deadband, the previous mode is kept.
        if ( e < -mode_deadband / 2.0_wp ) then
            mode = 0
        else if ( e > mode_deadband / 2.0_wp ) then
            mode = 1
        else
            mode = int(GetOutputValue(3))  ! take mode at last iteration, instead of last timestep
        end if
        if (mode /= prev_mode) t_fm = 0.0_wp  ! reset timer if the mode has changed
    end if
end if
call SetDynamicArrayValueThisIteration(4, real(mode, wp))  ! store mode for this timestep
call SetDynamicArrayValueThisIteration(15, t_fm)  ! store fixed operationg mode timer for this timestep


! Get air flow rate
old_AFRlevel = int(GetDynamicArrayValueLastTimestep(5))
! Get the air flow rate level from the setpoint error and hysteresis loops
if (AFRlevel == 0) then
    AFRlevel = GetLevel(s(Ni)%AFRerror(:, mode), s(Ni)%AFRdb(:, mode), e, old_AFRlevel, mode)
else if (mode == 0) then
    AFRlevel = s(Ni)%nAFR(0) + 1 - AFRlevel
end if
AFR = s(Ni)%AFR(AFRlevel, mode)
call SetDynamicArrayValueThisIteration(5, real(AFRlevel, wp))

! Get frequency limits
if (fmin < 0.0_wp) then
    Toalevel = FindLevel(s(Ni)%Toa0(:, mode), Toa, s(Ni)%nf0(mode) - 1)
    fmin = s(Ni)%f0(Toalevel, mode)
end if

fmaxBoost = .false.
if (fmax < 0.0_wp) then
    if (mode == 0) then
        old_zone = int(GetDynamicArrayValueLastTimestep(6))
        t_boost = int(GetDynamicArrayValueLastTimestep(7))
        zone = GetLevel(s(Ni)%Toa2, s(Ni)%db2, Toa, old_zone, 1)  ! determine the temperature zone (fig. 3.5)
        call SetDynamicArrayValueThisIteration(6, real(zone, wp))
        AFR2level = FindLevel(s(Ni)%AFR2, AFR, s(Ni)%nAFR2)  ! find level corresponding to the AFR value
        if ( AFR2level > s(Ni)%nAFR2 ) AFR2level = s(Ni)%nAFR2
        if ( t_boost < s(Ni)%t_boost_max ) then  ! use the boost frequency only for a limited time period
            fmax = s(Ni)%f2(zone, AFR2level)
        else  ! If the maximum time is exceeded, use the steady-state maximum frequency (scaled down version of f2)
            fmax = s(Ni)%f2(zone, AFR2level) * s(Ni)%f1f2
        end if
        fmaxBoost = .true.
    else
        fmax = s(Ni)%f2heat  ! single value for the maximum frequency in heating mode
    end if
end if

if ( defrost_mode == -1 .and. mode == 1 ) call SetDefrostMode(defrost_mode)  ! automatic defrost selection
if (mode == 1) recov_penalty = RecoveryPenalty(t_ld, t_rec)  ! if () because risk of division by zero


if (mode == 1 .and. defrost_mode == 0) then
    fq = 1.0_wp  ! Fix rated frequency during defrost
    fi = 0.0_wp  ! Reset integral
else
    ! Assign fixed frequency value depending on error signal
    modulate = .false.
    if (onOff <= 0) then
        fi = 0.0_wp
        fq = 0.0_wp
    else if ( e < s(Ni)%e_min(mode) ) then  ! e < e_min
        fq = (1 - real(mode, wp)) * fmax  ! 0 in heating, fmax in cooling
    else if ( e > s(Ni)%e_max(mode) ) then  ! e > e_max
        fq = real(mode, wp) * fmax  ! fmax in heating, 0 in cooling
    else
        modulate = .true.
    end if

    ! Adjust the sign of the error depending on the operating mode
    e = (Tset - Tr) * (2.0_wp * real(mode, wp) - 1.0_wp)
    call RecallStoredPIvalues()
    fqLastTimestep = GetDynamicArrayValueLastTimestep(13)
    fqLastIteration = GetOutputValue(1)

    if (modulate) then
        ! Default values for extra parameters
        if (tt < 0.0_wp) tt = ti
        if (b < 0.0_wp) b = 1.0_wp

        fp = Kc * (b*Tset - Tr) * (2.0_wp * real(mode, wp) - 1.0_wp)  ! Proportional signal
        if (ti > 0.0_wp) then  ! Integral action
            fi = fi_old + Kc / ti * dt * (e + e_old) / 2  ! Update the integral (using trapezoidal integration).
        else
            fi = fi_old
        end if
        f = fp + fi  ! Unsaturated signal
        if ( tt > 0.0_wp .and. (f < fmin .or. f > fmax) ) then
            es = f - min(fmax, TrimLow(f, fmin))  ! Error with saturated signal
            fi = fi - dt * (es + es_old) / 2 / tt  ! De-saturate integral signal
            f = fp + fi  ! Re-calculate the unsaturated signal
        end if
        fsat = min(fmax, TrimLow(f, fmin))  ! Saturated signal
        fq = (1.0_wp * floor(N * fsat)) / (1.0_wp * N)  ! Quantized signal
        if ( GetTimestepIteration() > 0 ) then
            if ( (fqLastIteration == 0.0_wp) .and. (fq > 0.0_wp) .or. &
                 (fqLastIteration > 0.0_wp) .and. (fq == 0.0_wp) ) then
                nIter = nIter + 1
            end if
            if (nIter > nIterMax) then
                fq = fqLastIteration
            else
                nIter = 0
            end if
        end if
    else
        fi = 0.0_wp
    !else if ((ti > 0.0_wp) .and. (onOff > 0)) then  ! even though there is no frequency modulation, the integral must be updated
        !fi = fi_old + Kc / ti * dt * (e + e_old) / 2
    end if
    call StorePIvalues()

    t_mnt = GetDynamicArrayValueLastTimestep(12)
    dfdt_sign_prev = int(GetDynamicArrayValueLastTimestep(14))
    if (fq > fqLastTimestep) then  ! frequency is increasing
        dfdt_sign = 1
    else if (fq < fqLastTimestep) then  ! frequency is decreasing
        dfdt_sign = -1
    else
        dfdt_sign = dfdt_sign_prev
    end if

    if ( dfdt_sign * dfdt_sign_prev == -1 ) then  ! previous timestep was a local extremum
        if (t_mnt <= t_mnt_min) then
            fq = fqLastTimestep  ! keep the previous frequency value
            t_mnt = t_mnt + dt  ! increment monotonous frequency timer
            dfdt_sign = dfdt_sign_prev  ! keep the same direction of frequency evolution
        else
            t_mnt = 0.0_wp  ! reset the timer
        end if
    else
        t_mnt = t_mnt + dt
    end if
    call SetDynamicArrayValueThisIteration(12, t_mnt)
    call SetDynamicArrayValueThisIteration(13, fq)
    call SetDynamicArrayValueThisIteration(14, real(dfdt_sign, wp))

    if ( abs(fq - fmax) < 0.001_wp .and. fmaxBoost ) then  ! Heat pump operates at boost frequency
        t_boost = t_boost + dt  ! increment the boost frequency timer
    else
        t_boost = 0.0_wp  ! reset the timer
    endif
    call SetDynamicArrayValueThisIteration(7, real(t_boost, wp))
end if

call SetOutputValues()

return

    contains

    subroutine ReadControlFiles(LUc, LUh)
        character (len=maxPathLength) :: cfCoolPath
        character (len=maxPathLength) :: cfHeatPath
        integer, intent(in) :: LUc, LUh
        integer :: nAFRmax, nf0max, i, j, LUs(2), LUcool(1), LUheat(1)
        LUcool(1) = LUc
        LUheat(1) = LUh

        ! Ni = GetCurrentUnit()
        LUs = (/LUc, LUh/)

        cfCoolPath = GetLUfileName(LUc)
        cfHeatPath = GetLUfileName(LUh)
        call CheckControlFile(cfCoolPath)
        call CheckControlFile(cfHeatPath)
        if (ErrorFound()) return

        open(LUh, file=cfHeatPath, status='old')
        open(LUc, file=cfCoolPath, status='old')

            call SkipLines(LUs, 6)
        read(LUc, *) s(Ni)%e_min(0)
        read(LUh, *) s(Ni)%e_min(1)
            call SkipLines(LUs, 2)
        read(LUc, *) s(Ni)%e_max(0)
        read(LUh, *) s(Ni)%e_max(1)
            call SkipLines(LUs, 3)
        read(LUc, *) s(Ni)%nAFR(0)
        read(LUh, *) s(Ni)%nAFR(1)
        nAFRmax = maxval(s(Ni)%nAFR)
            call SkipLines(LUs, 1)
        allocate(s(Ni)%AFR(nAFRmax, 0:1))
        read(LUc, *) (s(Ni)%AFR(i, 0), i = 1, s(Ni)%nAFR(0))
        read(LUh, *) (s(Ni)%AFR(i, 1), i = 1, s(Ni)%nAFR(1))
            call SkipLines(LUs, 4)
        allocate(s(Ni)%AFRerror(nAFRmax - 1, 0:1))
        allocate(s(Ni)%AFRdb(nAFRmax - 1, 0:1))
        do i = 1, s(Ni)%nAFR(0) - 1
            read(LUc, *) s(Ni)%AFRerror(i, 0), s(Ni)%AFRdb(i, 0)
            read(LUh, *) s(Ni)%AFRerror(i, 1), s(Ni)%AFRdb(i, 1)
        enddo
            call SkipLines(LUs, 3)
        read(LUc, *) s(Ni)%nf0(0)
        read(LUh, *) s(Ni)%nf0(1)
        nf0max = maxval(s(Ni)%nf0)
            call SkipLines(LUs, 2)
        allocate(s(Ni)%Toa0(nf0max - 1, 0:1))
        allocate(s(Ni)%f0(nf0max, 0:1))
        read(LUc, *) (s(Ni)%Toa0(i, 0), i = 1, s(Ni)%nf0(0) - 1)
        read(LUh, *) (s(Ni)%Toa0(i, 1), i = 1, s(Ni)%nf0(1) - 1)
        read(LUc, *) (s(Ni)%f0(i, 0), i = 1, s(Ni)%nf0(0))
        read(LUh, *) (s(Ni)%f0(i, 1), i = 1, s(Ni)%nf0(1))
            call SkipLines(LUheat, 2)
        read(LUh, *) s(Ni)%f2heat
            call SkipLines(LUheat, 8)
        read(LUh, *) s(Ni)%Tcutoff, s(Ni)%t_df
            call SkipLines(LUheat, 2)
        read(LUh, *) (s(Ni)%t_h(i), i = 1, 4)
            call SkipLines(LUheat, 2)
        read(LUh, *) (s(Ni)%t_rec(i), i = 1, 2), s(Ni)%Tmin
        close(LUh)
            call SkipLines(LUcool, 3)
        read(LUc, *) s(Ni)%t_boost_max, s(Ni)%f1f2
            call SkipLines(LUcool, 1)
        read(LUc, *) s(Ni)%nZones, s(Ni)%nAFR2
            call SkipLines(LUcool, 6)
        allocate(s(Ni)%Toa2(s(Ni)%nZones - 1))
        allocate(s(Ni)%db2(s(Ni)%nZones - 1))
        allocate(s(Ni)%AFR2(s(Ni)%nAFR2))
        allocate(s(Ni)%f2(s(Ni)%nZones, s(Ni)%nAFR2))
        do i = 1, s(Ni)%nZones - 1
            read(LUc, *) s(Ni)%Toa2(i), s(Ni)%db2(i)
        end do
            call SkipLines(LUcool, 1)
        read(LUc, *) (s(Ni)%AFR2(j), j = 1, s(Ni)%nAFR2)
            call SkipLines(LUcool, 1)
        do i = 1, s(Ni)%nZones
            read(LUc, *) (s(Ni)%f2(i, j), j = 1, s(Ni)%nAFR2)
        end do

        close(LUc)

    end subroutine ReadControlFiles


    subroutine CheckControlFile(cfPath)
        logical :: ControlFileFound = .false.
        character (len=maxPathLength) :: cfPath
        character (len=maxMessageLength) :: msg
        inquire(file=trim(cfPath), exist=ControlFileFound)
        if ( .not. ControlFileFound ) then
            write(msg,'("""",a,"""")') trim(cfPath)
            msg = "Could not find the specified performance map file. Searched for: " // trim(msg)
            call Messages(-1, msg, 'fatal', thisUnit, thisType)
            return
        end if
    end subroutine CheckControlFile


    subroutine SkipLines(LUs, N)
    ! Skip lines in several files at once
    !
    ! Inputs
    !   LUs (integer array) : logical unit of each file
    !                         where lines must be skipped.
    !   N (integer) : number of lines to skip.
        integer, intent(in) :: LUs(:)
        integer :: i, j, N
        do i = 1, size(LUs)
            do j = 1, N
                read(LUs(i), *)
            end do
        end do
    end subroutine SkipLines


    function GetLevel(centers, deadbands, value, old_level, hyst_dir) result(level)
    ! Determine the output (called the "level") of an hysteresis function based
    ! on an input value and the old level. The hysteresis is characterised by
    ! its center(s), deadband(s), and its direction (ascending or descending).
    ! There can be several cascading hysteresis; in that case the centers and
    ! deadbands must be given as arrays. An exemple with two ascending hystersis
    ! loops would look like this :
    !                                  <---deadband2--->
    !                                  ---------------------    Level 3
    !                                  |       |       |
    !                                  |       |       |
    !       <-deadband1->              |       |       |
    !       -----------------------------------|--------        Level 2
    !       |     |     |                   center2
    !       |     |     |
    !       |     |     |
    !   ----------|------                                       Level 1
    !          center1
    !
    ! Inputs
    !   centers (real(wp) array) : centers of the hysteresis deadbands.
    !   deadbands (real(wp) array) : width of each deadband.
    !   value (real(wp)) : input value.
    !   old_level (integer) : the output value at the previous timestep
    !                         (NOT at the previous iteration).
    !   hyst_dir (integer) : direction of the hysteresis loops
    !                        (0 = descending, 1 = ascending)
    !
    ! Output
    !   level (integer) : the output value for the current timestep.
        real(wp), intent(in) :: centers(:), deadbands(:), value
        integer, intent(in) :: old_level, hyst_dir
        real(wp) :: hdb(size(deadbands))
        integer :: level, idx
        logical :: valueInLowDb, valueInHighDb
        hdb = deadbands / 2.0_wp  ! half deadbands
        level = FindLevel(centers, value, size(centers))
        
        ! Check whether the value is within a deadband
        if (level == 1) then
            valueInLowDb = .false.
            valueInHighDb = value > centers(1) + hdb(1)
        else if ( level == size(centers) + 1 ) then
            valueInLowDb = value < centers(size(centers)) + hdb(size(hdb))
            valueInHighDb = .false.
        else
            valueInLowDb = value < centers(level - 1) + hdb(level - 1)
            valueInHighDb = value > centers(level) + hdb(level)
        end if
        
        ! FindLevel works for ascending hysteresis -> adjust level if descending
        if (hyst_dir == 0) level = size(centers) + 2 - level
        
        ! If the value is within a deadband, adjust the level based on the old level.        
        if (valueInLowDb) then
            if ( old_level < level .and. hyst_dir == 1 ) then
                level = level - 1
            else if ( old_level > level .and. hyst_dir == 0 ) then
                level = level + 1
            end if
        else if (valueInHighDb) then
            if ( old_level > level .and. hyst_dir == 1 ) then
                level = level + 1
            else if ( old_level < level .and. hyst_dir == 0 ) then
                level = level - 1
            end if
        end if
    end function GetLevel

    
    function FindLevel(array, value, extent) result(level)
    ! Find the level among the (ordered) array of centers.
    ! If the value v is located in the interval A(i) < v < A(i+1)
    ! where A is the array, the function returns i+1. If v = A(i),
    ! then it returns i. Finally, if v < A(1), the function returns 1,
    ! and if v > A(end), it returns size(A) + 1.
    !
    ! Inputs
    !   array (real(wp) array) : array with values in ascending order.
    !   value (real(wp)) : value to search in the array.
    !   extent (integer) : size of the array.
    !
    ! Output
    !   level (integer) : level of the value in the array.
        real(wp), intent(in) :: array(:), value
        integer, intent(in) :: extent
        integer :: level
        integer :: L, R, mid
        if ( value > array(extent) ) then
            level = extent + 1
        else
            L = 1
            R = extent
            do while (L < R)
                mid = (L + R) / 2  ! L & R are integers -> automatic floor
                if (array(mid) < value) then
                    L = mid + 1
                else
                    R = mid
                end if
            end do
            level = L
        end if
    end function FindLevel


    subroutine SetDefrostMode(defrost_mode)
    ! Choose the defrost mode based on different parameters
    ! located in the global scope.
    !
    ! Inputs
    !   defrost_mode (integer) : variable to which the subroutine assigns the
    !                            defrost mode:
    !                               0 = defrost operation
    !                               1 = recovery
    !                               2 = steady-state operation
        integer :: defrost_mode
        real(wp) :: Tcutoff, t_cycle, t_h, t_df
        real(wp) :: a, b, c, d, m, p, Tmin, Tmax
        ! regression parameters
        Tcutoff = s(Ni)%Tcutoff
        t_df = s(Ni)%t_df / 60.0_wp
        a = s(Ni)%t_h(1) / 60.0_wp
        b = s(Ni)%t_h(2) / 60.0_wp
        c = s(Ni)%t_h(3)
        d = s(Ni)%t_h(4)
        m = s(Ni)%t_rec(1) / 60.0_wp
        p = s(Ni)%t_rec(2) / 60.0_wp
        Tmin = s(Ni)%Tmin
        Tmax = -p / m  ! temperature at which t_rec becomes zero

        call RecallStoredDefrostValues()

        Toa_av = (t_ld*Toa_av_prev + dt*Toa) / (t_ld + dt)  ! update mean temperature
        t_h = a + b * exp(c * (Toa_av + d))
        if (Toa_av > Tmax) then
            t_rec = 0.0_wp
        else if (Toa_av >= Tmin) then
            t_rec = m * Toa_av + p
        else
            t_rec = 37.0_wp / 60.0_wp
        end if
        t_cycle = t_h + t_df

        if (Toa < Tcutoff) then
            t_uc = t_uc + dt
        else
            t_oc = t_oc + dt
        end if
        
        t_ld = t_ld + dt  ! increment time since last defrost

        if (t_ld < t_rec) then  ! recovery
            defrost_mode = 1
        else if (t_ld < t_h) then  ! steady-state
            defrost_mode = 2
        else if (t_uc < t_oc) then  ! Toa above treshold
            t_uc = 0.0_wp  ! reset cutoff temperature timers
            t_oc = 0.0_wp
            t_ld = t_rec  ! begin steady-state
            defrost_mode = 2
        else if (t_ld < t_cycle) then  ! defrost
            defrost_mode = 0
        else  ! end of defrost cycle, reset everything
            t_ld = 0.0_wp
            t_uc = 0.0_wp
            t_oc = 0.0_wp
            Toa_av = 0.0_wp
            defrost_mode = 1
        end if
        call StoreDefrostValues()
    end subroutine SetDefrostMode
    
    
    function TrimLow(f, fmin) result(ftrimmed)
    ! Trim f to value fmin if fmin/2 < f < fmin, and to zero if f < fmin/2.
        real(wp), intent(in) :: f, fmin
        real(wp) :: ftrimmed
        ftrimmed = merge(merge(0.0_wp, fmin, f < fmin/2.0_wp), f, f < fmin)
    end function TrimLow
    

    subroutine StorePIvalues
        call SetDynamicArrayValueThisIteration(1, e)
        call SetDynamicArrayValueThisIteration(2, fi)
        call SetDynamicArrayValueThisIteration(3, es)
    end subroutine StorePIvalues


    subroutine RecallStoredPIvalues
        e_old = GetDynamicArrayValueLastTimestep(1)
        fi_old = GetDynamicArrayValueLastTimestep(2)
        es_old = GetDynamicArrayValueLastTimestep(3)
    end subroutine RecallStoredPIvalues


    subroutine StoreDefrostValues
        call SetDynamicArrayValueThisIteration(8, t_ld)
        call SetDynamicArrayValueThisIteration(9, t_uc)
        call SetDynamicArrayValueThisIteration(10, t_oc)
        call SetDynamicArrayValueThisIteration(11, Toa_av)
    end subroutine StoreDefrostValues


    subroutine RecallStoredDefrostValues
        t_ld = GetDynamicArrayValueLastTimestep(8)
        t_uc = GetDynamicArrayValueLastTimestep(9)
        t_oc = GetDynamicArrayValueLastTimestep(10)
        Toa_av_prev = GetDynamicArrayValueLastTimestep(11)
    end subroutine RecallStoredDefrostValues

    
    function RecoveryPenalty(t_ld, t_rec) result(penalty)
    ! Compute the capacity correction factor in recovery mode,
    ! after the defrost is finished.
    !
    ! Inputs
    !   t_ld (real(wp)) : the time since the end of the last defrost.
    !   t_rec (real(wp)) : the duration of the recovery (between defrost and steady-state).
    !
    ! Output
    !   penalty (real(wp)) : the recovery penalty (between 0 and 1).
        real(wp), intent(in) :: t_ld, t_rec
        real(wp) :: penalty, t_dimless
        if (t_rec < 1e-15) then
            penalty = 1.0_wp
        else
            t_dimless = t_ld / t_rec
            penalty = 2*t_dimless - t_dimless**2
        end if
    end function RecoveryPenalty


    subroutine ExecuteFirstCallOfSimulation
        call SetNumberofParameters(6)
	    call SetNumberofInputs(14)
	    call SetNumberofDerivatives(0)
	    call SetNumberofOutputs(5)
	    call SetIterationMode(1)
	    call SetNumberStoredVariables(0, 15)
	    call SetNumberofDiscreteControls(0)

        ! Allocate stored data structure
        if ( .not. allocated(s) ) then
            allocate(s(Ninstances))
        endif

        call ReadParameters()  ! required to get LUcool and LUheat
        call ReadControlFiles(LUcool, LUheat)

    end subroutine ExecuteFirstCallOfSimulation


    subroutine ExecuteStartTime
        call ReadParameters()
        call GetInputValues()
	    call SetOutputValue(1, 0.0_wp)  ! Normalized frequency
        call SetOutputValue(2, 0.0_wp)  ! Normalized air flow rate
        call SetOutputValue(3, 0.0_wp)  ! Operating mode
        call SetOutputValue(4, 0.0_wp)  ! Defrost mode
        call SetOutputValue(5, 0.0_wp)  ! Defrost recovery penalty

        call SetDynamicArrayInitialValue(1, 0.0_wp)  ! Error signal
        call SetDynamicArrayInitialValue(2, 0.0_wp)  ! Integral value
        call SetDynamicArrayInitialValue(3, 0.0_wp)  ! Saturation error
        call SetDynamicArrayInitialValue(4, 0.0_wp)  ! Operating mode
        call SetDynamicArrayInitialValue(5, 1.0_wp)  ! Air flow rate level
        call SetDynamicArrayInitialValue(6, 1.0_wp)  ! Outdoor temperature zone
        call SetDynamicArrayInitialValue(7, 0.0_wp)  ! Boost frequency operation time
        call SetDynamicArrayInitialValue(8, 0.0_wp)  ! Time since last defrost
        call SetDynamicArrayInitialValue(9, 0.0_wp)  ! Time under cutoff frequency
        call SetDynamicArrayInitialValue(10, 0.0_wp)  ! Time over cutoff frequency
        call SetDynamicArrayInitialValue(11, 0.0_wp)  ! Average outdoor temperature
        call SetDynamicArrayInitialValue(12, 0.0_wp)  ! Time during which the frequency is forced constant
        call SetDynamicArrayInitialValue(13, 0.0_wp)  ! Previous frequency value
        call SetDynamicArrayInitialValue(14, 0.0_wp)  ! Previous frequency derivative sign
        call SetDynamicArrayInitialValue(15, 0.0_wp)  ! Duration of fixed mode operation
    end subroutine ExecuteStartTime


    subroutine ExecuteEndOfTimestep
        continue
        nIter = 0
    end subroutine ExecuteEndOfTimestep


    subroutine ExecuteLastCallOfSimulation
        continue
    end subroutine ExecuteLastCallOfSimulation


    subroutine ReadParameters
        mode_deadband = GetParameterValue(1)
        t_fm_min = GetParameterValue(2) / 60.0_wp
        t_mnt_min = GetParameterValue(3) / 60.0_wp
        nIterMax = GetParameterValue(4)
        LUcool = GetParameterValue(5)
        LUheat = GetParameterValue(6)
    end subroutine ReadParameters

    subroutine GetInputValues
        onOff = GetInputValue(1)
        Tset = GetInputValue(2)
        AFR = GetInputValue(3)
        ! Tr = nint(GetInputValue(4)*100.0_wp)/100.0_wp ! round to 0.2 °C to avoid oscillations
        Tr = GetInputValue(4)
        Toa = GetInputValue(5)
        fmin = GetInputValue(6)
        fmax = GetInputValue(7)
        mode = GetInputValue(8)
        defrost_mode = GetInputValue(9)
        N = GetInputValue(10)
        Kc = GetInputValue(11)
        ti = GetInputValue(12)
        tt = GetInputValue(13)
        b = GetInputValue(14)
    end subroutine GetInputValues


    subroutine SetOutputValues
        call SetOutputValue(1, fq)  ! Normalized saturated quantized frequency
        call SetOutputValue(2, AFR)  ! Normalized air flow rate
        call SetOutputValue(3, real(mode, wp))  ! Operating mode
        call SetOutputValue(4, real(defrost_mode, wp))  ! Defrost mode
        call SetOutputValue(5, recov_penalty)  ! Defrost recovery penalty
        return
    end subroutine SetOutputValues


    subroutine GetTRNSYSvariables
        time = GetSimulationTime()
        dt = GetSimulationTimeStep()
        thisUnit = GetCurrentUnit()
        thisType = GetCurrentType()
    end subroutine GetTRNSYSvariables

end subroutine Type3223
