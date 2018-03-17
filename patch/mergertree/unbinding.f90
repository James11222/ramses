#if NDIM==3
subroutine unbinding()

  use amr_commons    ! MPI stuff
  use pm_commons, only: mp, npart, npartmax, levelp
  use hydro_commons, ONLY:mass_sph
  use clfind_commons ! unbinding stuff

  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
  integer :: info
  real(dp) :: partm_common_all
#endif

  !------------------------------------------------------------
  ! This subroutine assigns all particles that are in cells
  ! identified to be in a clump by the clump finder the peak
  ! ID of that clump and checks whether they are energetically
  ! bound to that structure. If not, they are passed on to the
  ! clump's parents.
  !------------------------------------------------------------

  integer           :: ipeak, ilevel, ipart, i, parent_local_id
  integer           :: loop_counter=0
  integer, dimension(1:npart) :: clump_ids
  character(LEN=80)     :: fileloc
  character(LEN=5)      :: nchar,nchar2
  logical           :: loop_again_global, is_final_round, check




  !========================
  ! Initial set-up
  !========================

  !Logging/Announcing stuff
  if(myid==1) write(*,*) "Started unbinding."


  !update boundary relevance
  call build_peak_communicator
  call boundary_peak_dp(relevance)
  !call boundary_peak_int(new_peak) ! already done in clump_finder, doesn't 
                                    ! need an update
  call boundary_peak_int(lev_peak)

  
  ! set up constants and counters
  GravConst=1d0      ! Gravitational constant
  if(cosmo) GravConst=3d0/8d0/3.1415926*omega_m*aexp

  periodical=(nx==1) ! true if periodic
  nunbound=0         ! count unbound particles
  candidates=0       ! count unbinding candidates: Particles of child clumps
                     ! that will be tested. If a particle is passed on to the
                     ! parent clump, it will be counted twice.

  progenitorcount = 0         ! count clumps that will be progenitors in the next snapshot
  progenitorcount_written = 0 ! count halos that you'll write to file for mergertree
                     
  killed_tot = 0; appended_tot = 0; ! count how many too small clumps have been dissolved             
  ! make sure things are done at least once
  mergelevel_max = max(mergelevel_max, 1)





   !get particle mass (copied from subroutine write_clump_properties)
  if(ivar_clump==0)then
    partm_common=MINVAL(mp, MASK=(mp.GT.0.))
#ifndef WITHOUTMPI  
    call MPI_ALLREDUCE(partm_common,partm_common_all,1,MPI_DOUBLE_PRECISION,MPI_MIN,MPI_COMM_WORLD,info)
    partm_common=partm_common_all  
#endif
  else
    if(hydro)then 
      partm_common=mass_sph
    endif
  endif
                    
  
                     
                     
                     
  ! allocate necessary arrays
  call allocate_unbinding_arrays()



  !===================
  ! Gather particles 
  !===================

  !Get particles in substructrue, create linked lists
  call get_clumpparticles()

  !write output if required. This gives the particle clump assignment as given
  !by PHEW.
  ! if (unbinding_formatted_output) call write_unbinding_formatted_output(.true.)



  !==================
  ! Unbinding loop
  !==================

  ! go level by level
  do ilevel=0, mergelevel_max

    !---------------------------------
    ! Preparation for iteration loop 
    !---------------------------------

    is_final_round=.true.
    if (iter_properties) is_final_round=.false.
    
    loop_again=.true.
    loop_counter=0

    ! reset values
    to_iter = (lev_peak==ilevel)


    hasatleastoneptcl=1 ! set array value to 1



    !-------------------------
    ! iteration per level
    !-------------------------

    do while(loop_again)
      loop_again = .false.  ! set boolean whether to continue to false as default;
                            ! will get reset if conditions are met

      loop_counter=loop_counter+1
      niterunbound=0

      !--------------------------------------------------------
      ! get particle based clump properties :
      ! bulk velocity, particle furthest away from density peak
      !--------------------------------------------------------
      call get_clump_properties_pb(loop_counter==1)


      if (loop_counter==repeat_max) loop_again=.false.

      !sync with other processors wheter you need to repeat loop
#ifndef WITHOUTMPI
      call MPI_ALLREDUCE(loop_again, loop_again_global, 1, MPI_LOGICAL, MPI_LOR,MPI_COMM_WORLD, info)
      loop_again=loop_again_global
#endif

      !-------------------------------
      ! get cumulative mass profiles
      !-------------------------------
      call get_cmp()

      
      !-----------------------------------------
      ! get closest border to the peak position
      !-----------------------------------------
      if (saddle_pot) call get_closest_border()


      !---------------
      ! Unbinding 
      !---------------
      if (.not.loop_again) is_final_round=.true.
      do ipeak=1, hfree-1
        ! don't apply to_iter here!
        ! needs to be done in final round even if to_iter = .false.
        check = clmp_mass_pb(ipeak)>0.0 .and. lev_peak(ipeak) == ilevel
        if (check) then
          call particle_unbinding(ipeak, is_final_round)
        end if
      end do



      !------------------------
      ! prepare for next round
      !------------------------

      if (loop_again) then
        ! communicate whether peaks have remaining contributing particles
        call build_peak_communicator()
        call virtual_peak_int(hasatleastoneptcl,'max')
        call boundary_peak_int(hasatleastoneptcl)

        do ipeak=1,hfree-1

          !if peak has no contributing particles anymore
          if (hasatleastoneptcl(ipeak)==0) then
            to_iter(ipeak)=.false. !dont loop anymore over this peak
          end if

          if (loop_counter == 1) then ! only do this for first round
            call get_local_peak_id(new_peak(ipeak), parent_local_id)
            if(ipeak==parent_local_id) then 
              ! Don't iterate over halo-namegivers.
              ! Only set here to false, so they'll be considered
              ! every first time the loop over levels starts.
              to_iter(ipeak) = .false. !don't iterate over halo namegivers 
            end if 
          endif

        end do

      else !if it is final round
      
        if(make_mergertree) call dissolve_small_clumps(ilevel, .false.)
        call dissolve_small_clumps(ilevel, .false.)
      
      end if


      !---------------------
      ! Talk to me.
      !---------------------
      if (clinfo .and. iter_properties) then 

#ifndef WITHOUTMPI
        call MPI_ALLREDUCE(niterunbound, niterunbound_tot, 1, MPI_INTEGER, MPI_SUM,MPI_COMM_WORLD, info)
#else
        niterunbound_tot=niterunbound
#endif
        if (myid==1) then
          write(*,'(A10,I10,A30,I5,A7,I5)') " Unbound", niterunbound_tot, &
            "particles at level", ilevel, "loop", loop_counter
        end if
      end if


      if (.not. loop_again .and. clinfo .and. myid==1 .and. &
        iter_properties .and. loop_counter < repeat_max) then
        write(*, '(A7,I5,A35,I5,A12)') "Level ", ilevel, &
          "clump properties converged after ", loop_counter, "iterations."
      end if

      if (loop_counter==repeat_max) write(*,'(A7,I5,A20,I5,A35)') "Level ", ilevel, &
        "not converged after ", repeat_max, "iterations. Moving on to next step."

    end do ! loop again for ilevel

  end do !loop over levels


  ! After the loop: Dissolve too small halos
  ! if (make_mergertree) call dissolve_small_clumps(0, .true.)
  call dissolve_small_clumps(0, .true.)
  



  !================================
  ! Talk to me when unbinding done
  !================================


  if (clinfo) then
#ifndef WITHOUTMPI
    call MPI_ALLREDUCE(nunbound, nunbound_tot, 1, MPI_INTEGER, MPI_SUM,MPI_COMM_WORLD, info)
    call MPI_ALLREDUCE(candidates, candidates_tot, 1, MPI_INTEGER, MPI_SUM,MPI_COMM_WORLD, info)
#else
    nunbound_tot=nunbound
    candidates_tot=candidates
#endif
    if (myid==1) then
      write(*,'(A6,I10,A30,I10,A12)') " Found", nunbound_tot, "unbound particles out of ", candidates_tot, " candidates"
    end if
  end if
   








  !=========================================
  ! After unbinding: Do merger tree stuff
  !=========================================

  call deallocate_unbinding_arrays(.true.)

  if (make_mergertree) then
    if (myid==1)write(*,*) "Calling merger tree"
    call make_merger_tree()
  endif






  !=================
  ! Write output
  !=================

  if(unbinding_formatted_output) call write_unbinding_formatted_output(.false.)
  
  call title(ifout-1, nchar)
  call title(myid, nchar2)
  fileloc=TRIM('output_'//TRIM(nchar)//'/unbinding.out'//TRIM(nchar2))

  open(unit=666,file=fileloc,form='unformatted')
  

  ipart=0
  do i=1,npartmax
    if(levelp(i)>0)then
      ipart=ipart+1
      clump_ids(ipart)=clmpidp(i)
    end if
  end do
  write(666) clump_ids
  close(666)



  !====================
  ! Say good bye.
  !====================
  if(verbose.or.myid==1) write(*,*) "Finished unbinding."



  !====================
  ! Deallocate arrays
  !====================
  call deallocate_unbinding_arrays(.false.)


end subroutine unbinding
!######################################
!######################################
!######################################
subroutine get_clumpparticles()

  !---------------------------------------------------------------------------
  ! This subroutine loops over all test cells and assigns all particles in a
  ! testcell the peak ID the testcell has. If the peak is not a namegiver
  ! (= not its own parent), the particles are added to a linked list for 
  ! unbinding later.
  !---------------------------------------------------------------------------

  use amr_commons
  use clfind_commons        !unbinding stuff is all in here
  use pm_commons, only: numbp, headp, nextp, xp 
  use amr_parameters
  use hydro_commons         !using mass_sph
  implicit none
  
  ! for looping over test cells and getting particle list
  integer   :: itestcell, ipart,this_part, global_peak_id, local_peak_id, prtcls_in_grid 
  
  ! getting particles per peak
  integer   :: ind, grid


  !getting in which cell of a grid a particle is
  integer   :: part_cell_ind,i,j,k

  !appending linked lists
  integer   :: ipeak, new_peak_local_id, ilevel






  if(verbose) write(*,*) "Entered get_clumpparticles"





  !-----------------------------------------------------------
  ! Get particles from testcells into linked lists for clumps
  !-----------------------------------------------------------

  do itestcell=1, ntest !loop over all test cells
    global_peak_id=flag2(icellp(itestcell))

    if (global_peak_id /= 0) then

      ! get local peak id
      call get_local_peak_id(global_peak_id, local_peak_id)

      if (relevance(local_peak_id) > relevance_threshold) then
        ! create linked particle list

        ind=(icellp(itestcell)-ncoarse-1)/ngridmax+1    ! get cell position
        grid=icellp(itestcell)-ncoarse-(ind-1)*ngridmax ! get grid index
        prtcls_in_grid = numbp(grid)                    ! get number of particles in grid
        this_part=headp(grid)                           ! get index of first particle

         
        !loop over particles in grid
        do ipart=1, prtcls_in_grid
          !check cell index of particle so you loop only once over each
          i=0
          j=0
          k=0
          if(xg(grid,1)-xp(this_part,1)/boxlen+(nx-1)/2.0 .le. 0) i=1
          if(xg(grid,2)-xp(this_part,2)/boxlen+(ny-1)/2.0 .le. 0) j=1
          if(xg(grid,3)-xp(this_part,3)/boxlen+(nz-1)/2.0 .le. 0) k=1

          part_cell_ind=i+2*j+4*k+1
  
          ! If index is correct, assign clump id to particle
          if (part_cell_ind==ind) then
            ! assign peak ID
            clmpidp(this_part)=global_peak_id
            ! add particle to linked list of clumpparticles 
            ! check if already particles are assigned
            if (nclmppart(local_peak_id)>0) then
              ! append to the last particle of the list
              clmppart_next(clmppart_last(local_peak_id))=this_part
            else
              ! assign particle as first particle
              ! for this peak of linked list 
              clmppart_first(local_peak_id)=this_part
            end if
            ! update last particle for this clump
            nclmppart(local_peak_id)=nclmppart(local_peak_id)+1
            clmppart_last(local_peak_id)=this_part
          end if    
          ! go to next particle in this grid
          this_part=nextp(this_part)
        end do
      end if     ! if clump is relevant
    end if       ! global peak /=0
  end do         ! loop over test cells




  !------------------------------------------------------
  ! Append substructure particles to parents' linked list
  !------------------------------------------------------
  
  ! first do it for subhalos only to get full lists
  ! must be done level by level!
  do ilevel=0,mergelevel_max
    do ipeak=1, hfree-1
      ! append substructure linked lists to parent linked lists
      if(lev_peak(ipeak)==ilevel) then
        if (nclmppart(ipeak)>0) then
          ! get local id of parent
          call get_local_peak_id(new_peak(ipeak),new_peak_local_id)
          ! append particle LL to parent's LL if parent isn't a halo-namegiver
          if(ipeak/=new_peak_local_id) then !if peak is namegiver, don't append to yourself
            ! It might happen that the parent peak doesn't have a 
            ! particle linked list yet (on this processor).
            if (nclmppart(new_peak_local_id)>0) then !particle ll exists
              clmppart_next(clmppart_last(new_peak_local_id))=clmppart_first(ipeak)
            else
              clmppart_first(new_peak_local_id)=clmppart_first(ipeak)
            end if

            clmppart_last(new_peak_local_id)=clmppart_last(ipeak)
            nclmppart(new_peak_local_id)=nclmppart(new_peak_local_id)+nclmppart(ipeak)
          end if
        end if
      end if
    end do
  end do



end subroutine get_clumpparticles
!########################################
!########################################
!########################################
subroutine get_clump_properties_pb(first)
  use amr_commons
  use pm_commons, only: mp, xp, vp
  use clfind_commons
  implicit none

  logical, intent(in) :: first  ! if it is the first time calculating
   
  !--------------------------------------------------------------------------
  ! This subroutine computes the particle-based properties of the clumps:
  ! namely the center of mass and the clump's velocity.
  ! If it's called for the first time, it will compute the properties for
  ! all peak IDs. If not, it will go level by level.
  !--------------------------------------------------------------------------

  ! particle furthest away
  real(dp) :: distance, biggest

  ! iterators
  integer :: ipeak, i, ipart, parent_local_id
  integer :: thispart

  real(dp) :: vsq
  real(dp),dimension(1:3) :: period
  real(dp),dimension(1:npeaks_max) :: clmp_vel_sq_pb_old
  logical :: check
  

  if (verbose) write(*,*) "Entered get_clump_properties (particle based)"


  !------------------------------------------------------------
  ! If iterative: Store old values, reset virtual peak values
  !------------------------------------------------------------

  do ipeak=1, hfree-1
    check = (.not. first) .and. to_iter(ipeak)
    if (check) then
      clmp_vel_sq_pb_old(ipeak)=clmp_vel_pb(ipeak,1)**2+clmp_vel_pb(ipeak,2)**2+clmp_vel_pb(ipeak,3)**2
      do i=1,3
        oldvel(ipeak,i)=clmp_vel_pb(ipeak,i)
      end do
      oldcmpd(ipeak)=cmp_distances(ipeak,nmassbins)
      oldm(ipeak)=clmp_mass_pb(ipeak)
    end if

    if (iter_properties .and. ipeak>npeaks) then  
      ! for communication: set virtual peak values=0
      ! so they won't contribute in the communication sum
      ! reset values
      do i=1,3
        clmp_vel_pb(ipeak,i)=0.0
      end do
      clmp_mass_pb(ipeak)=0.0
    end if
  end do  


  !------------------------------------------------------
  ! GET CENTER OF MASS, CENTER OF MOMENTUM FRAME VELOCITY
  !------------------------------------------------------

  do ipeak=1, hfree-1 !loop over all peaks

    if (to_iter(ipeak)) then ! if peak has particles and needs to be iterated over

      ! reset values
      do i=1,3
        clmp_vel_pb(ipeak,i)=0.0
      end do
      cmp_distances(ipeak,nmassbins)=0.0
      clmp_mass_pb(ipeak)=0.0


      if (hasatleastoneptcl(ipeak)>0 .and. nclmppart(ipeak)>0) then 
        ! if there is work to do on this processing unit for this peak

        thispart=clmppart_first(ipeak)
        
        do ipart=1, nclmppart(ipeak)       ! while there is a particle linked list
          if (contributes(thispart)) then  ! if the particle should be considered
            clmp_mass_pb(ipeak)=clmp_mass_pb(ipeak)+mp(thispart)
            do i=1,3
              clmp_vel_pb(ipeak,i)=clmp_vel_pb(ipeak,i)+vp(thispart,i)*mp(thispart) !get velocity sum
            end do
          else
            contributes(thispart)=.true. ! reset value
          end if
          thispart=clmppart_next(thispart) ! go to next particle in linked list
        end do   ! loop over particles
      end if     ! there is work for this peak on this processor
    end if       ! peak needs to be looked at
  end do         ! loop over peaks


  !----------------------------------------------------------------------
  ! communicate clump mass and velocity across processors
  !----------------------------------------------------------------------
  call build_peak_communicator
  call virtual_peak_dp(clmp_mass_pb,'sum')       !collect
  call boundary_peak_dp(clmp_mass_pb)            !scatter
  do i=1,3
    call virtual_peak_dp(clmp_vel_pb(1,i),'sum')  !collect
    call boundary_peak_dp(clmp_vel_pb(1,i))       !scatter
  end do

  !------------------------------------------------------------
  ! get more work done
  !------------------------------------------------------------



  do ipeak=1, hfree-1

    check = to_iter(ipeak)
    check = check .and. clmp_mass_pb(ipeak)>0

    if (check) then
      ! calculate actual CoM and center of momentum frame velocity
      do i=1,3
        clmp_vel_pb(ipeak,i)=clmp_vel_pb(ipeak,i)/clmp_mass_pb(ipeak)
      end do

      !------------------------------------
      ! FIND PARTICLE FURTHEST AWAY FROM CoM
      !------------------------------------
      ! The maximal distance of a particle to the CoM is saved in the last
      ! cmp_distances array for every peak.
      if(nclmppart(ipeak)>0) then
        biggest=0.0
        thispart=clmppart_first(ipeak)
        do ipart=1, nclmppart(ipeak) ! while there is a particle linked list

          period=0.d0

          if (periodical) then
            do i=1, 3
              if (xp(thispart,i)-peak_pos(ipeak,i)>0.5*boxlen) period(i)=(-1.0)*boxlen
              if (xp(thispart,i)-peak_pos(ipeak,i)<(-0.5*boxlen)) period(i)=boxlen
            end do
          end if

          distance=(xp(thispart,1)+period(1)-peak_pos(ipeak,1))**2 + &
            (xp(thispart,2)+period(2)-peak_pos(ipeak,2))**2 + &
            (xp(thispart,3)+period(3)-peak_pos(ipeak,3))**2

          if(distance>biggest) biggest=distance ! save if it is biggest so far

          thispart=clmppart_next(thispart)

        end do
        if (biggest>0.0) cmp_distances(ipeak,nmassbins)=sqrt(biggest) !write if you have a result
      end if ! to iterate
    end if
  end do     ! over all peaks

  !-------------------------------------------------
  ! communicate distance of particle furthest away
  !-------------------------------------------------
  call build_peak_communicator
  call virtual_peak_dp(cmp_distances(1,nmassbins), 'max')
  call boundary_peak_dp(cmp_distances(1,nmassbins))



  !-------------------------------------------------
  ! If iterative clump properties determination:
  ! Check whether bulk velocity converged
  !-------------------------------------------------

  if (iter_properties) then ! if clump properties will be determined iteratively
    do ipeak=1, hfree-1

      call get_local_peak_id(new_peak(ipeak),parent_local_id )
      ! is a halo-namegiver

      check = to_iter(ipeak)
      check = check .and. ipeak /= parent_local_id 
      check = check .and. clmp_mass_pb(ipeak)>0.0

      if (check) then
        vsq=clmp_vel_pb(ipeak,1)**2+clmp_vel_pb(ipeak,2)**2+clmp_vel_pb(ipeak,3)**2

        if ( abs( sqrt(clmp_vel_sq_pb_old(ipeak)/vsq) - 1.0) < conv_limit ) then
          to_iter(ipeak) = .false. ! consider bulk velocity as converged
          !write(*,'(A8,I3,A15,I8,A6,E15.6E2,A5,E15.6E2,A7,E15.6E2,A9,E15.6E2)') &
          !& "#####ID", myid, "clump CONVERGED", ipeak+ipeak_start(myid), "old:", &
          !& clmp_vel_sq_pb_old(ipeak), "new:", vsq, "ratio",  abs( sqrt(clmp_vel_sq_pb_old(ipeak)/vsq) - 1.0),&
          !& "v_bulk=", sqrt(vsq)
        else
          loop_again=.true. !repeat
        end if
      end if
    end do
  end if


end subroutine get_clump_properties_pb 
!###################################
!###################################
!###################################
subroutine get_cmp()

  use amr_commons
  use pm_commons
  use clfind_commons
  implicit none

  !----------------------------
  !Get cumulative mass profiles
  !----------------------------

  integer  :: ipeak, i, ipart, levelmax
  real(dp) :: r_null, distance
  integer  :: thispart
  real(dp),dimension(1:3) :: period
  logical  :: check
   
#ifndef WITHOUTMPI
  integer  :: levelmax_glob, info
  include 'mpif.h'
#endif

  if(verbose) write(*,*) "Entered get cumulative mass profiles"

  if (logbins) then
    !get minimal distance:
    levelmax=0
    do i=1,nlevelmax
       if(numbtot(1,i)>0) levelmax=levelmax+1
    end do

#ifndef WITHOUTMPI
    ! get system-wide levelmax
    call MPI_ALLREDUCE(levelmax,levelmax_glob, 1, MPI_INTEGER, MPI_MAX,MPI_COMM_WORLD, info)

    levelmax=levelmax_glob
#endif

    rmin=boxlen/2**levelmax
  end if




  do ipeak=1, hfree-1

    !peak must have need to be reiterated
    check=to_iter(ipeak)
    check=check.and.nclmppart(ipeak)>0           !peak must have particles on this processor      

    !reset values
    if (check .or. ipeak > npeaks) then
      do i = 1, nmassbins
        cmp(ipeak,i) = 0.0
      end do
    end if


    if (check) then
      !------------------------------------------
      !Compute cumulative mass binning distances
      !------------------------------------------
      !The distances are not communicated later, but computed on each
      !processor independently, because each processor has all information it needs 
      !with cmp_distances(ipeak,nmassbins) and CoM

      if (logbins) then
        do i=1, nmassbins-1
          cmp_distances(ipeak,i)=rmin*(cmp_distances(ipeak,nmassbins)/rmin)**(real(i)/real(nmassbins))
        end do
      else !linear binnings
        r_null=cmp_distances(ipeak,nmassbins)/real(nmassbins)
        do i=0, nmassbins-1
          cmp_distances(ipeak,i)=r_null*i
        end do
      end if
      !The last bin must end with precicely with the maximal 
      !Distance of the particle. That is
      !needed because precision errors. The maximal distance is 
      !computed via particle data and the outermost bin is equal
      !to the distance of the outermost particle to the CoM.
      !Precision errors cause the code to crash here.

      !---------------------------------------------
      ! bin particles in cumulative mass profiles:
      ! get mass of each bin
      ! calculate particle distance to CoM
      !---------------------------------------------
      thispart=clmppart_first(ipeak)
      do ipart=1, nclmppart(ipeak)!while there is a particle linked list
        period=0.d0
        if (periodical) then
          do i=1, 3
            if (xp(thispart,i)-peak_pos(ipeak,i)>0.5*boxlen)  period(i)=(-1.0)*boxlen
            if (xp(thispart,i)-peak_pos(ipeak,i)<(-0.5*boxlen)) period(i)=boxlen
          end do
        end if
        distance=(xp(thispart,1)+period(1)-peak_pos(ipeak,1))**2 + &
          (xp(thispart,2)+period(2)-peak_pos(ipeak,2))**2 + &
          (xp(thispart,3)+period(3)-peak_pos(ipeak,3))**2
        distance=sqrt(distance)


        i=1
        do 
          if (distance<=cmp_distances(ipeak,i)) then
            cmp(ipeak,i) = cmp(ipeak,i ) + mp(thispart)
            exit
          else
            i=i+1
          end if
        end do

        thispart=clmppart_next(thispart)
      end do

      ! sum up masses to get profile instead of mass in shell
      do i=0,nmassbins-1
        cmp(ipeak,i+1)=cmp(ipeak,i+1)+cmp(ipeak,i) 
      end do

    end if  ! check
  end do    ! loop over peaks

  !--------------------------------------  
  !communicate cummulative mass profiles
  !--------------------------------------  
  call build_peak_communicator()
  do i=1,nmassbins
    call virtual_peak_dp(cmp(1,i), 'sum')
    call boundary_peak_dp(cmp(1,i)) 
  end do

end subroutine get_cmp
!########################################
!########################################
!########################################
subroutine get_closest_border()
  use amr_commons
  use clfind_commons
  implicit none
  !---------------------------------------------------------------------------
  ! Find closest border to centre of mass. Modified subroutine saddlepoint_search
  !---------------------------------------------------------------------------
  integer                         ::  ipart,ipeak,ip,jlevel,next_level
  integer                         ::  local_peak_id,global_peak_id
  integer,dimension(1:nvector)    ::  ind_cell
  logical,dimension(1:npeaks_max) ::  check
  
  ! character(len=80) :: fileloc
  ! character(len=5)  :: nchar, nchar2

  if(verbose)write(*,*) "Entered get_closest_border"

  check=.false.
  do ipeak=1, hfree-1

    check(ipeak)=cmp_distances(ipeak,nmassbins)>0.0 ! peak must have particles somewhere
    check(ipeak)=check(ipeak).and.to_iter(ipeak)

    if(check(ipeak))  closest_border(ipeak) = 3.d0*boxlen**2 !reset value
  end do



  !-------------------------
  ! Loop over all testcells
  !-------------------------
  ip=0
  do ipart=1,ntest
    jlevel=levp(ipart)  ! level
    next_level=0        ! level of next particle
    if(ipart<ntest)next_level=levp(ipart+1)

    
    global_peak_id=flag2(icellp(ipart))
    if (global_peak_id/=0) then 

      call get_local_peak_id(global_peak_id,local_peak_id)

      if(check(local_peak_id)) then ! if testcell is of interest:
        ip=ip+1
        ind_cell(ip)=icellp(ipart)
        if(ip==nvector .or. next_level /= jlevel)then
          call unbinding_neighborsearch(ind_cell,ip,jlevel)
          ip=0
        endif
      endif
    end if
  end do
  if (ip>0)call unbinding_neighborsearch(ind_cell,ip,jlevel)

  !------------------------
  ! Communicate results
  !------------------------

  call build_peak_communicator()
  call virtual_peak_dp(closest_border,'min')
  call boundary_peak_dp(closest_border)



end subroutine get_closest_border
!#####################################################
!#####################################################
!#####################################################
!#####################################################
subroutine unbinding_neighborsearch(ind_cell,np,jlevel)
  use amr_commons
  implicit none
  integer,dimension(1:nvector),intent(in) :: ind_cell  ! array of indices of cells that I want to check
  integer,intent(in)                      :: np        ! number of actual cells in ind_cell
  integer,intent(in)                      :: jlevel    ! cell level

  !------------------------------------------------------------
  ! Modified subroutine neighborsearch
  ! This routine constructs all neighboring leaf cells at levels 
  ! jlevel-1, jlevel, jlevel+1.
  ! Then performs the check if the neighbors are a border
  ! in order to find the closest border to the center of mass
  !------------------------------------------------------------

  integer::j,ind,nx_loc,i1,j1,k1,i2,j2,k2,i3,j3,k3,ix,iy,iz
  integer::i1min,i1max,j1min,j1max,k1min,k1max
  integer::i2min,i2max,j2min,j2max,k2min,k2max
  integer::i3min,i3max,j3min,j3max,k3min,k3max
  real(dp)::dx,dx_loc,scale
  integer ,dimension(1:nvector)::clump_nr,indv,ind_grid,grid,ind_cell_coarse

  real(dp),dimension(1:twotondim,1:3)::xc
  integer ,dimension(1:99)::neigh_cell_index,cell_levl,test_levl
  real(dp),dimension(1:99,1:ndim)::xtest,xrel
  logical ,dimension(1:99)::ok
  real(dp),dimension(1:3)::skip_loc
  integer ,dimension(1:nvector,1:threetondim),save::nbors_father_cells
  integer ,dimension(1:nvector,1:twotondim),save::nbors_father_grids 
  integer::ntestpos,ntp,idim,ipos

  real(dp),dimension(1:3)::this_cellpos



  ! Mesh spacing in that level
  dx=0.5D0**jlevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  !skip_loc=(/0.0d0,0.0d0,0.0d0/)
  skip_loc(1)=dble(icoarse_min)
  skip_loc(2)=dble(jcoarse_min)
  skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale

  ! Integer constants
  i1min=0; i1max=1; i2min=0; i2max=2; i3min=0; i3max=3
  j1min=0; j1max=1; j2min=0; j2max=2; j3min=0; j3max=3
  k1min=0; k1max=1; k2min=0; k2max=2; k3min=0; k3max=3

  ! Cells center position relative to grid center position
  do ind=1,twotondim
    iz=(ind-1)/4
    iy=(ind-1-4*iz)/2
    ix=(ind-1-2*iy-4*iz)
    xc(ind,1)=(dble(ix)-0.5D0)*dx
    xc(ind,2)=(dble(iy)-0.5D0)*dx
    xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do
  
  ! some preliminary action...
  do j=1,np
    indv(j)   = (ind_cell(j)-ncoarse-1)/ngridmax+1         ! cell position in grid
    ind_grid(j) = ind_cell(j)-ncoarse-(indv(j)-1)*ngridmax ! grid index
    clump_nr(j) = flag2(ind_cell(j))                       ! save clump number
  end do 




  ntestpos=3**ndim
  if(jlevel>levelmin)  ntestpos=ntestpos+2**ndim
  if(jlevel<nlevelmax) ntestpos=ntestpos+4**ndim

  !===================================
  ! generate neighbors level jlevel-1
  !===================================
  ntp=0
  if(jlevel>levelmin)then
    ! Generate 2x2x2  neighboring cells at level jlevel-1   
    do k1=k1min,k1max
      do j1=j1min,j1max
        do i1=i1min,i1max     
          ntp=ntp+1
          xrel(ntp,1)=(2*i1-1)*dx_loc
          xrel(ntp,2)=(2*j1-1)*dx_loc
          xrel(ntp,3)=(2*k1-1)*dx_loc
          test_levl(ntp)=jlevel-1
        end do
      end do
    end do
  endif

  !=====================================
  ! generate neighbors at level jlevel
  !=====================================
  ! Generate 3x3x3 neighboring cells at level jlevel
  do k2=k2min,k2max
    do j2=j2min,j2max
      do i2=i2min,i2max
        ntp=ntp+1
        xrel(ntp,1)=(i2-1)*dx_loc
        xrel(ntp,2)=(j2-1)*dx_loc
        xrel(ntp,3)=(k2-1)*dx_loc
        test_levl(ntp)=jlevel
      end do
    end do
  end do
  
  !=====================================
  ! generate neighbors at level jlevel+1
  !=====================================
  if(jlevel<nlevelmax)then
    ! Generate 4x4x4 neighboring cells at level jlevel+1
    do k3=k3min,k3max
      do j3=j3min,j3max
        do i3=i3min,i3max
          ntp=ntp+1
          xrel(ntp,1)=(i3-1.5)*dx_loc/2.0
          xrel(ntp,2)=(j3-1.5)*dx_loc/2.0
          xrel(ntp,3)=(k3-1.5)*dx_loc/2.0
          test_levl(ntp)=jlevel+1
        end do
      end do
    end do
  endif



  ! Gather 27 neighboring father cells (should be present anytime !)
  do j=1,np
    ind_cell_coarse(j)=father(ind_grid(j))
  end do
  call get3cubefather(ind_cell_coarse,nbors_father_cells,nbors_father_grids,np,jlevel)


  do j=1,np
    ok=.false.
    do idim=1,ndim
      ! get real coordinates of neighbours
      xtest(1:ntestpos,idim)=(xg(ind_grid(j),idim)+xc(indv(j),idim)-skip_loc(idim))*scale+xrel(1:ntestpos,idim)
      if(jlevel>levelmin)xtest(1:twotondim,idim)=xtest(1:twotondim,idim)+xc(indv(j),idim)*scale
    end do
    grid(1)=ind_grid(j)
    call get_cell_index_fast(neigh_cell_index,cell_levl,xtest,ind_grid(j),nbors_father_cells(j,1:threetondim),ntestpos,jlevel)
   
    do ipos=1,ntestpos
      ! make sure neighbour is a leaf cell
      if(son(neigh_cell_index(ipos))==0.and.cell_levl(ipos)==test_levl(ipos)) then
        ok(ipos)=.true. 
      end if
    end do
   
    ! get position of the cell whose neighbours will be tested
    do idim=1,ndim
      this_cellpos(idim)=(xg(ind_grid(j),idim)+xc(indv(j),idim)-skip_loc(idim))*scale
    end do

    ! check neighbors
    call bordercheck(this_cellpos,clump_nr(j),xtest,neigh_cell_index,ok,ntestpos)
    ! bordercheck (this_cellpos=position of cell to test;
    ! clump_nr(j)=peak ID of cell to test;
    ! xtest=positions of neighbour cells; 
    ! neigh_cell_index=index of neighbour cells;
    ! ok = if neighbour cell is leaf cell;
    ! ntestpos = how many neighbour cells there are
  end do

end subroutine unbinding_neighborsearch
!########################################
!########################################
!########################################
subroutine bordercheck(this_cellpos,clump_nr,xx,neigh_cell_index,ok,np)
  !----------------------------------------------------------------------
  ! routine to check wether neighbor belongs to another clump and is closer to the center
  ! of mass than all others before
  ! modified subroutine saddlecheck
  !----------------------------------------------------------------------
  use amr_commons
  use clfind_commons
  implicit none
  real(dp), dimension(1:np,1:ndim), intent(in)  :: xx               ! positions of neighbour cells
  real(dp), dimension(1:ndim),      intent(in)  :: this_cellpos     ! position of test cell whose neighbours 
                                                                    ! are to be tested
  integer,  dimension(1:99),        intent(in)  :: neigh_cell_index ! cell index of neighbours
  integer,                          intent(in)  :: clump_nr         ! global peak ID of cell whose neighbours
                                                                    ! will be tested
  logical,  dimension(1:99),      intent(inout) :: ok               ! wether cell should be checkedre
  integer,                          intent(in)  :: np               ! number of neighbours to be looped over


  real(dp), dimension(1:99,1:ndim)  :: pos        ! position of border for each neighbour
  integer,  dimension(1:99)         :: neigh_cl   ! clump number of neighbour,local peak id of neighbour
  real(dp)                          :: newsum
  integer                           :: i,j,ipeak
  real(dp), dimension(1:3)          :: period


  do j=1,np
    neigh_cl(j)=flag2(neigh_cell_index(j)) ! index of the clump the neighboring cell is in 

    ok(j)=ok(j).and. clump_nr/=0           ! temporary fix...
    ok(j)=ok(j).and. neigh_cl(j)/=0        ! neighboring cell is in a clump. If neighbour not in clump, clump is still considered isolated.
    ok(j)=ok(j).and. neigh_cl(j)/=clump_nr ! neighboring cell is in another clump 
  end do


  call get_local_peak_id(clump_nr,ipeak)

  do j=1,np
    if(ok(j))then ! if all criteria met, you've found a neighbour cell that belongs to a different clump 

      period=0.d0
      if (periodical) then
        do i=1, ndim
          if (xx(j,i)-peak_pos(ipeak,i) > 0.5*boxlen)    period(i)=(-1.0)*boxlen
          if (xx(j,i)-peak_pos(ipeak,i) < (-0.5*boxlen)) period(i)=boxlen
        end do
      end if

      do i=1, ndim
        ! the cells will be nighbours, so no need to compute two different periodic corrections
        pos(j,i)=(xx(j,i)+period(i)+this_cellpos(i)+period(i))*0.5 
      end do

      newsum=0
      do i=1, ndim
        newsum=newsum+(pos(j,i)-peak_pos(ipeak,i))**2
      end do

      if (newsum<closest_border(ipeak))  closest_border(ipeak)=newsum
      end if
  end do


end subroutine bordercheck
!########################################
!########################################
!########################################
subroutine particle_unbinding(ipeak, final_round)
  use amr_commons, only: dp
  use clfind_commons

  implicit none
  integer, intent(in) :: ipeak       ! peak to loop over
  logical, intent(in) :: final_round ! if it is the final round => whether to write
  !--------------------------------------------------------------
  ! This subroutine loops over all particles in the linked list of
  ! peak ipeak and checks if they are bound.
  ! Also identifies the nmost_bound most strongly bound particles
  ! Of each clump.
  !--------------------------------------------------------------

  integer :: thispart, ipeak_test, ipart, parent_local_id=0, n=0, n_temp=0
  real(dp):: phi_border   ! the potential at the border of the peak patch closest 
                          ! to the center of mass
  real(dp):: dist_border  !distance to the border

  real(dp), dimension(:), allocatable:: particle_energy
  integer, dimension(:), allocatable:: particle_energy_id
  real(dp) :: epart 


  

  call get_local_peak_id(new_peak(ipeak), parent_local_id)

  ! compute the potential for this peak on the points of the mass bin distances
  if (nclmppart(ipeak) > 0) call compute_phi(ipeak)


  !-----------------------------------------------
  ! If not namegiver
  !-----------------------------------------------
  if (parent_local_id /= ipeak) then

    ! compute potential at the closest border from the center of mass
    phi_border=0.d0
    if(saddle_pot) then
      dist_border=sqrt(closest_border(ipeak))
      if(dist_border<=cmp_distances(ipeak,nmassbins)) call potential(ipeak, dist_border, phi_border)
    end if



    !--------------------------------
    ! Not namegiver, final round
    !--------------------------------

    if (final_round) then
      ! store energy and particle clump ID in a list

      if ( nclmppart(ipeak) > 0 ) then
        if (make_mergertree) then
          allocate(particle_energy(1:nclmppart(ipeak)))
          particle_energy = HUGE(0.d0)
          allocate(particle_energy_id(1:nclmppart(ipeak)))
          particle_energy_id = 0
        endif


        !loop through particle list
        thispart=clmppart_first(ipeak)

        do ipart=1, nclmppart(ipeak)    ! loop over particle LL
          call get_local_peak_id(clmpidp(thispart), ipeak_test)
          if (ipeak_test==ipeak) then   ! if this particle needs to be checked for unbinding
                                        ! particle may be assigned to child/parent clump
            candidates=candidates+1

            call eparttot(ipeak, thispart, epart)
            epart = epart + phi_border

            !check if unbound
            if(epart >= 0) then  
              nunbound=nunbound+1                  !counter
              clmpidp(thispart)=new_peak(ipeak)    !update clump id
            else
              if (make_mergertree) then
                ! store the values for mergertrees
                particle_energy(ipart) = epart
                particle_energy_id(ipart) = thispart
              endif
            end if
          end if
          thispart=clmppart_next(thispart)
        end do


        if (make_mergertree) then
          ! sort particles by lowest energy
          ! sort the particle ID's accordingly
          call quick_sort_real_int(particle_energy, particle_energy_id, nclmppart(ipeak)) 
          n_temp = min(nclmppart(ipeak), nmost_bound)
         
          ! find whether you really have only bound particles
          if (particle_energy(n_temp) >= 0.0) then ! there are unbound particles before index n
            do ipart = 1, n_temp
              if (particle_energy(ipart) >= 0.0) then
                n = ipart - 1
                exit
              end if
            end do
          else
            n = n_temp
          end if


          if (n > 0) then
            ! store bound and sorted particles
            do ipart = 1, n
              most_bound_energy(ipeak, ipart) = particle_energy(ipart)
              most_bound_pid(ipeak, ipart) = particle_energy_id(ipart)
            end do

            ! count output  += 1
            progenitorcount_written = progenitorcount_written + 1
          endif

          deallocate(particle_energy_id, particle_energy)
        endif ! if make_mergertree

      

      end if ! there are particles on this proc



      



    !--------------------------------
    ! Not namegiver, not final round
    ! (= usual iterative unbinding)
    !--------------------------------

    else ! not final round
      if (to_iter(ipeak)) then
        hasatleastoneptcl(ipeak)=0       ! set to false

        ! loop through particle list
        thispart=clmppart_first(ipeak)
        
        do ipart=1, nclmppart(ipeak)     ! loop over particle LL
          call get_local_peak_id(clmpidp(thispart),ipeak_test) 
          if (ipeak_test==ipeak) then   ! if this particle needs to be checked for unbinding
            call eparttot(ipeak, thispart, epart)
            if(epart + phi_border >= 0.0 ) then

              niterunbound=niterunbound+1
              contributes(thispart) = .false.   ! particle doesn't contribute to
                                                ! clump properties
            else
              hasatleastoneptcl(ipeak)=1 ! there are contributing particles for this peak
            end if
          endif
          thispart=clmppart_next(thispart)
        end do

      end if 
    end if

  !-----------------------------------------------
  ! If namegiver
  !-----------------------------------------------
  else ! is namegiver; only find most bound for mergertrees
    if (final_round .and. make_mergertree) then
      ! store energy and particle clump ID in a list

      if ( nclmppart(ipeak) > 0 ) then
        allocate(particle_energy(1:nclmppart(ipeak)))
        particle_energy = HUGE(0.d0)
        allocate(particle_energy_id(1:nclmppart(ipeak)))
        particle_energy_id = 0

        ! loop through particle list
        thispart=clmppart_first(ipeak)

        do ipart=1, nclmppart(ipeak)    ! loop over particle LL
          call get_local_peak_id(clmpidp(thispart),ipeak_test)
          if (ipeak_test==ipeak) then   ! if this particle needs to be checked for unbinding
                                        ! particle may be assigned to child/parent clump
            ! store the values for mergertrees
            call eparttot(ipeak, thispart, epart)
            particle_energy(ipart) = epart
            particle_energy_id(ipart) = thispart
          end if
          thispart=clmppart_next(thispart)
        end do


        ! sort particles by lowest energy
        call quick_sort_real_int(particle_energy, particle_energy_id, nclmppart(ipeak)) 
        n_temp = min(nclmppart(ipeak), nmost_bound)
       
        ! find whether you really have only bound particles
        if (particle_energy(n_temp) >= 0.0) then !there are unbound particles before index n
          do ipart = 1, n_temp
            if (particle_energy(ipart) >= 0.0) then
              n = ipart - 1
              exit
            end if
          end do
        else
          n = n_temp
        end if

        do ipart = 1, n
          most_bound_energy(ipeak,ipart) = particle_energy(ipart)
          most_bound_pid(ipeak, ipart) = particle_energy_id(ipart)
        end do
        if (n > 0) then
          ! store bound and sorted particles
          do ipart = 1, n
            most_bound_energy(ipeak, ipart) = particle_energy(ipart)
            most_bound_pid(ipeak, ipart) = particle_energy_id(ipart)
          end do

          ! count output  += 1 to estimate array sizes
          progenitorcount_written = progenitorcount_written + 1
        endif

        deallocate(particle_energy_id, particle_energy)

      endif 
    endif ! final round and mergertrees
  end if  ! namegiver or not
end subroutine particle_unbinding
!############################################################################
!############################################################################
!############################################################################
!############################################################################
subroutine eparttot(ipeak, part_ind, epart)
  !-----------------------------------------------------------
  ! This function calculates the total energy of the particle
  ! with index part_ind assigned to clump ipeak.
  !-----------------------------------------------------------

  use pm_commons
  use clfind_commons
  implicit none

  integer, intent(in) :: ipeak, part_ind
  real(dp),intent(out):: epart
  real(dp) :: distance, kinetic_energy, minusphi
  real(dp),dimension(1:3) :: period
  integer :: i

  period=0.d0
  if (periodical) then
    do i=1, ndim
      if (xp(part_ind,i)-peak_pos(ipeak,i) > 0.5*boxlen   ) period(i)=(-1.0)*boxlen
      if (xp(part_ind,i)-peak_pos(ipeak,i) < (-0.5*boxlen)) period(i)=boxlen
    end do
  end if

  distance=(xp(part_ind,1)+period(1)-peak_pos(ipeak,1))**2 + &
      (xp(part_ind,2)+period(2)-peak_pos(ipeak,2))**2 + &
      (xp(part_ind,3)+period(3)-peak_pos(ipeak,3))**2
  distance=sqrt(distance)


  kinetic_energy=0.5*((vp(part_ind,1)-clmp_vel_pb(ipeak,1))**2 + &
      (vp(part_ind,2)-clmp_vel_pb(ipeak,2))**2 + &
      (vp(part_ind,3)-clmp_vel_pb(ipeak,3))**2)
  
  call potential(ipeak, distance, minusphi)

  epart = kinetic_energy - minusphi
end subroutine eparttot
!########################################################
!########################################################
!########################################################
!########################################################
subroutine potential(ipeak, distance, pot)
  !------------------------------------------------------------------
  ! This function interpolates the potential of a particle for given distance
  ! It returns (-1)*phi (phi is expected to be <= 0 for gravity)
  !------------------------------------------------------------------

  use clfind_commons

  integer, intent(in) :: ipeak
  real(dp),intent(in) :: distance  ! is computed in function 'unbound', then passed
  real(dp),intent(out):: pot

  integer :: ibin, thisbin
  real(dp) :: a,b

  ibin=1
  ! thisbin: the first cmp_distance which is greater than particle distance
  thisbin=1
  do 
    if (distance<=cmp_distances(ipeak,ibin)) then
      thisbin=ibin
      exit
    else
      ibin=ibin+1
    end if
  end do

  a=(phi_unb(thisbin)-phi_unb(thisbin-1))/(cmp_distances(ipeak,thisbin)-cmp_distances(ipeak,thisbin-1))
  b=phi_unb(thisbin-1)-a*cmp_distances(ipeak,thisbin-1)
  pot=(-1)*a*distance-b

end subroutine potential 



!###############################################
!###############################################
!###############################################
subroutine compute_phi(ipeak)
  !-----------------------------------------------------------
  ! This subroutine computes the potential on each massbin
  ! It writes potential[r=ibin] into the array phi_unb[ibin]
  !-----------------------------------------------------------
  use clfind_commons
  use amr_commons!, only: dp
  integer, intent(in) :: ipeak
  real(dp) :: delta,add
  integer  :: i

  ! Writing unformatted output
  !character(len=5)  :: bins
  !character(len=5)  :: peak
  !!character(len=10) :: peak !in case there are too many (>1E6) peaks
  !character(len=80) :: fileloc
  !character(len=5)  :: nchar

  ! compute part of integral/sum for each bin
  phi_unb(nmassbins)=0.0
  do i=2,nmassbins
    delta=cmp_distances(ipeak,i)-cmp_distances(ipeak,i-1)
    phi_unb(i-1)=-0.5*GravConst*(cmp(ipeak,i)/cmp_distances(ipeak,i)**2+cmp(ipeak,i-1)/cmp_distances(ipeak,i-1)**2)*delta
  end do
  delta=cmp_distances(ipeak,1)-cmp_distances(ipeak,0)
  phi_unb(0)=-0.5*GravConst*(cmp(ipeak,1)/cmp_distances(ipeak,1)**2)*delta

  !sum bins up
  !does not need to be done for i=nmassbins!
  add=-cmp(ipeak,nmassbins)/cmp_distances(ipeak,nmassbins)*GravConst !-G*M_tot/r_max
  do i=nmassbins-1,0,-1
    phi_unb(i)=phi_unb(i)+phi_unb(i+1) ! stops at phi_unb(1)
    phi_unb(i+1)=phi_unb(i+1)+add
  end do
  phi_unb(0)=phi_unb(0)+add ! bypass division by 0, needed for interpolation.

end subroutine compute_phi 
!###############################################
!###############################################
!###############################################
subroutine allocate_unbinding_arrays()
  use clfind_commons
  use pm_commons, only:npartmax
  implicit none

  !----------------------------------------------
  ! This subroutine allocates the necessary 
  ! arrays and gives them initial values.
  !----------------------------------------------


  !-------------------
  ! Clump properties
  !-------------------
  allocate(clmp_vel_pb(1:npeaks_max,1:3))
  clmp_vel_pb=0.0
  allocate(clmp_mass_pb(1:npeaks_max))
  clmp_mass_pb=0.0
  allocate(cmp_distances(1:npeaks_max,0:nmassbins))
  cmp_distances=0.0
  allocate(cmp(1:npeaks_max,0:nmassbins))
  cmp=0.d0
  ! careful with this! The first index of the second subscript
  ! of the cumulative mass aray (index 0) is there for reference
  ! for the enclosed mass interpolation.

  allocate(phi_unb(0:nmassbins)) ! array where to store the potential
  phi_unb=0.d0

  if (saddle_pot) then
    allocate(closest_border(1:npeaks_max)) ! point of the closest border to CoM
    closest_border=3.d0*boxlen**2
  end if

  allocate(to_iter(1:npeaks_max)) ! peak needs to be checked or not
  to_iter=.true.

  if (iter_properties) then
    allocate(oldvel(1:npeaks_max,1:3))
    allocate(oldcmpd(1:npeaks_max))
    allocate(oldm(1:npeaks_max))
  end if

  allocate(hasatleastoneptcl(1:npeaks_max))
  hasatleastoneptcl=1 ! initiate to yes


  !----------------------
  ! Particle linked list
  !----------------------
  allocate(clmpidp(1:npartmax))
  clmpidp=0

  allocate(clmppart_first(1:npeaks_max)) ! linked lists containing particles 
  clmppart_first=0

  allocate(clmppart_last(1:npeaks_max))  ! linked lists containing particles 
  clmppart_last=0

  allocate(clmppart_next(1:npartmax))    ! linked lists containing particles 
  clmppart_next=0

  allocate(nclmppart(1:npeaks_max))      ! linked lists containing particles 
  nclmppart=0

  allocate(contributes(1:npartmax))      ! particle contributes to clump properties or not
  contributes=.true.



  !------------------------
  ! Merger trees
  !------------------------

  !TODO: UNCOMMENT FOR MERGER
  ! if (make_mergertree) then
    allocate(most_bound_energy(1:npeaks_max, 1:nmost_bound))
    most_bound_energy = HUGE(0.d0)

    allocate(most_bound_pid(1:npeaks_max, 1:nmost_bound))
    most_bound_pid = 0

    allocate(clmp_mass_exclusive(1:npeaks_max))
    clmp_mass_exclusive = 0

    ! allocate(clmp_vel_exclusive(1:npeaks_max, 1:3))
    ! clmp_vel_exclusive = 0
  ! endif


end subroutine allocate_unbinding_arrays
!########################################
!########################################
!########################################
subroutine deallocate_unbinding_arrays(before_mergertree)
  use clfind_commons
  implicit none

  logical, intent(in) :: before_mergertree


  if (before_mergertree) then

    deallocate(clmp_mass_pb)

    if(saddle_pot) deallocate(closest_border)
    if (iter_properties) deallocate(oldvel,oldcmpd,oldm)

    deallocate(hasatleastoneptcl)
    deallocate(contributes)

  else

    deallocate(to_iter)
    deallocate(clmp_vel_pb)

    deallocate(phi_unb)
    deallocate(cmp)
    deallocate(cmp_distances)

    deallocate(clmpidp)
    deallocate(clmppart_last)
    deallocate(clmppart_first)
    deallocate(clmppart_next)
    deallocate(nclmppart)
  endif




end subroutine deallocate_unbinding_arrays
!############################################
!############################################
!############################################
subroutine write_unbinding_formatted_output(before)

  !--------------------------------------------------------------------
  ! This subroutine writes all the interesting particle attributes to
  ! file. 
  ! If before = .true. (called before the unbinding starts), it will 
  ! create a new directory "before" in the output directory and
  ! write the particle attributes as found by PHEW to file.
  !--------------------------------------------------------------------

  use amr_commons
  use pm_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
  integer :: info
#endif

  logical,intent(in) :: before
  
  !filename
  character(len=80) :: fileloc
  character(len=5)  :: nchar, nchar2

  !local vars
  integer       :: i
  character(len=80) :: cmnd

  if (before) then

    if (myid==1) then ! create before dir
      call title(ifout-1,nchar)
      cmnd='mkdir -p output_'//TRIM(nchar)//'/before'
      call system(TRIM(cmnd))
    end if

#ifndef WITHOUTMPI
  call MPI_BARRIER(MPI_COMM_WORLD,info)
#endif

  end if


  !generate filename
  call title(ifout-1, nchar)
  call title(myid, nchar2)

  if (before) then
    fileloc=TRIM('output_'//TRIM(nchar)//'/before/unb_form_out_particleoutput.txt'//nchar2)
  else
    fileloc=TRIM('output_'//TRIM(nchar)//'/unb_form_out_particleoutput.txt'//nchar2)
  end if

 

  open(unit=666, file=fileloc, form='formatted')
  write(666, '(9A18)') "x", "y", "z", "vx", "vy", "vz", "clmp id", "mass", "pid"
  do i=1, npartmax
    if(levelp(i)>0) then
      write(666, '(6E18.9E2,I18,E18.9E2,I18)') xp(i,1), xp(i,2), xp(i,3), vp(i,1), vp(i,2), vp(i,3), clmpidp(i),mp(i),idp(i)
    end if 
  end do

  close(666)
end subroutine write_unbinding_formatted_output
!#############################################
!#############################################
!#############################################

! endif: NDIM == 3
#endif
