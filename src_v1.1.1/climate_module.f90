MODULE climate_module

  USE mpi
  USE configuration_module,          ONLY: dp, C
  USE parallel_module,               ONLY: par, sync, ierr, cerr, write_to_memory_log, &
                                           allocate_shared_int_0D, allocate_shared_dp_0D, &
                                           allocate_shared_int_1D, allocate_shared_dp_1D, &
                                           allocate_shared_int_2D, allocate_shared_dp_2D, &
                                           allocate_shared_int_3D, allocate_shared_dp_3D, &
                                           deallocate_shared
  USE data_types_module,             ONLY: type_mesh, type_grid, type_ice_model, type_climate_model, type_init_data_fields, &
                                           type_climate_matrix, type_subclimate_global, type_subclimate_region, type_remapping, &
                                           type_ICE5G_timeframe, type_remapping_latlon2mesh, type_PD_data_fields, type_SMB_model
  USE utilities_module,              ONLY: error_function, smooth_Gaussian_2D
  USE netcdf_module,                 ONLY: debug, write_to_debug_file, inquire_PD_obs_data_file, read_PD_obs_data_file, inquire_GCM_snapshot, &
                                           read_GCM_snapshot, inquire_ICE5G_data, read_ICE5G_data
  USE mesh_help_functions_module,    ONLY: partition_list
  USE mesh_mapping_module,           ONLY: create_remapping_arrays_glob_mesh, map_latlon2mesh_2D, map_latlon2mesh_3D, deallocate_remapping_arrays_glob_mesh, &
                                           reallocate_field_dp, reallocate_field_dp_3D
  USE mesh_derivatives_module,       ONLY: get_mesh_derivatives
  USE forcing_module,                ONLY: forcing, map_insolation_to_mesh

  IMPLICIT NONE
    
CONTAINS

  ! Run the matrix climate model on a region mesh
  SUBROUTINE run_climate_model( mesh, ice, SMB, climate, time, region_name, grid_smooth)
    ! Run the regional climate model
    
    IMPLICIT NONE

    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    TYPE(type_SMB_model),                INTENT(IN)    :: SMB
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    REAL(dp),                            INTENT(IN)    :: time
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    
    ! Local variables:
    CHARACTER(LEN=64), PARAMETER                       :: routine_name = 'run_climate_model'
    INTEGER                                            :: n1, n2
    
    n1 = par%mem%n
    
    ! Check if we need to apply any special benchmark experiment climate
    IF (C%do_benchmark_experiment) THEN
      IF (C%choice_benchmark_experiment == 'EISMINT_1' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_2' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_3' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_4' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_5' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_6') THEN
        ! Parameterised climate needed for thermodynamics
        CALL EISMINT_climate( mesh, ice, climate, time)
        RETURN
      ELSEIF (C%choice_benchmark_experiment == 'Halfar' .OR. &
              C%choice_benchmark_experiment == 'Bueler' .OR. &
              C%choice_benchmark_experiment == 'MISMIP_mod' .OR. &
              C%choice_benchmark_experiment == 'mesh_generation_test') THEN
        ! Parameterised SMB and no thermodynamics; no climate needed
        RETURN
      ELSE
        WRITE(0,*) '  ERROR: benchmark experiment "', TRIM(C%choice_benchmark_experiment), '" not implemented in run_climate_model!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
    END IF ! IF (C%do_benchmark_experiment) THEN
    
    ! Update insolation forcing at model time
    CALL map_insolation_to_mesh( mesh, forcing%ins_t0, forcing%ins_t1, forcing%ins_Q_TOA0, forcing%ins_Q_TOA1, time, climate%applied%Q_TOA, climate%applied%Q_TOA_jun_65N, climate%applied%Q_TOA_jan_80S)
    
    ! Different kinds of climate forcing for realistic experiments
    IF (C%choice_forcing_method == 'd18O_inverse_dT_glob') THEN
      ! Use the global temperature offset as calculated by the inverse routine
      
      CALL run_climate_model_dT_glob( mesh, ice, climate, region_name)
      
    ELSEIF (C%choice_forcing_method == 'CO2_direct' .OR. C%choice_forcing_method == 'd18O_inverse_CO2') THEN
      ! Use CO2 (either taken directly from the specified record, or as calculated by the inverse routine) to force the climate matrix
      
      IF (C%choice_climate_matrix == 'PI_LGM') THEN
        ! Use the two-snapshot climate matrix
        CALL run_climate_model_matrix_PI_LGM( mesh, ice, SMB, climate, region_name, grid_smooth)
      ELSE
        IF (par%master) WRITE(0,*) '  ERROR: choice_climate_matrix "', TRIM(C%choice_climate_matrix), '" not implemented in run_climate_model!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
      
    ELSE
      IF (par%master) WRITE(0,*) '  ERROR: forcing method "', TRIM(C%choice_forcing_method), '" not implemented in run_climate_model!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
    
    n2 = par%mem%n
    !CALL write_to_memory_log( routine_name, n1, n2)
    
  END SUBROUTINE run_climate_model
  
  ! Parameterised climate (ERA40 + global temperature offset) from de Boer et al., 2013
  SUBROUTINE run_climate_model_dT_glob( mesh, ice, climate, region_name)
    ! Use the climate parameterisation from de Boer et al., 2013 (global temperature offset calculated with the inverse routine,
    ! plus a precipitation correction based on temperature + orography changes (NAM & EAS; Roe & Lindzen model), or only temperature (GRL & ANT).
    ! (for more details, see de Boer, B., van de Wal, R., Lourens, L. J., Bintanja, R., and Reerink, T. J.:
    ! A continuous simulation of global ice volume over the past 1 million years with 3-D ice-sheet models, Climate Dynamics 41, 1365-1384, 2013)
    
    IMPLICIT NONE

    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    TYPE(type_ice_model),                INTENT(IN)    :: ice 
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    
    ! Local variables:
    INTEGER                                            :: vi,m
    
    REAL(dp), DIMENSION(:    ), POINTER                :: dHs_dx_ref, dHs_dy_ref
    REAL(dp)                                           :: dT_lapse
    REAL(dp), DIMENSION(:,:  ), POINTER                :: Precip_RL_ref, Precip_RL_mod, dPrecip_RL
    INTEGER                                            :: wdHs_dx_ref, wdHs_dy_ref, wPrecip_RL_ref, wPrecip_RL_mod, wdPrecip_RL
    
    REAL(dp), PARAMETER                                :: P_offset = 0.008_dp       ! Normalisation term in precipitation anomaly to avoid divide-by-nearly-zero
    
    ! Allocate shared memory
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dx_ref   , wdHs_dx_ref   )
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dy_ref   , wdHs_dy_ref   )
    CALL allocate_shared_dp_2D( mesh%nV, 12, Precip_RL_ref, wPrecip_RL_ref)
    CALL allocate_shared_dp_2D( mesh%nV, 12, Precip_RL_mod, wPrecip_RL_mod)
    CALL allocate_shared_dp_2D( mesh%nV, 12, dPrecip_RL   , wdPrecip_RL   )
    
    ! Get surface slopes for the PD_obs reference orography
    CALL get_mesh_derivatives( mesh, climate%PD_obs%Hs_ref, dHs_dx_ref, dHs_dy_ref)

    ! Temperature: constant lapse rate plus global offset
    DO vi = mesh%v1, mesh%v2
    
      dT_lapse = (ice%Hs( vi) - climate%PD_obs%Hs_ref( vi)) * C%constant_lapserate
      DO m = 1, 12
        climate%applied%T2m( vi,m) = climate%PD_obs%T2m( vi,m) + dT_lapse + forcing%dT_glob_inverse
      END DO
      
    END DO
    CALL sync
    
    ! Precipitation: 
    ! NAM & EAS: Roe&Lindzen model to account for changes in orography and temperature
    ! GRL & ANT: simple correction based on temperature alone
    
    IF (region_name == 'NAM' .OR. region_name == 'EAS') THEN
    
      DO vi = mesh%v1, mesh%v2
      DO m = 1, 12
        
        CALL precipitation_model_Roe( climate%PD_obs%T2m(  vi,m), dHs_dx_ref( vi), dHs_dy_ref( vi), climate%PD_obs%Wind_LR( vi,m), climate%PD_obs%Wind_DU( vi,m), Precip_RL_ref( vi,m))
        CALL precipitation_model_Roe( climate%applied%T2m( vi,m), ice%dHs_dx( vi), ice%dHs_dy( vi), climate%PD_obs%Wind_LR( vi,m), climate%PD_obs%Wind_DU( vi,m), Precip_RL_mod( vi,m))
        dPrecip_RL( vi,m) = MIN( 2._dp, Precip_RL_mod( vi,m) / Precip_RL_ref( vi,m) )
        
        climate%applied%Precip( vi,m) = climate%PD_obs%Precip( vi,m) * dPrecip_RL( vi,m)
        
      END DO
      END DO
      CALL sync
    
    ELSEIF (region_name == 'GRL' .OR. region_name == 'ANT') THEN
    
      CALL adapt_precip_CC( mesh, ice%Hs, climate%PD_obs%Hs, climate%PD_obs%T2m, climate%PD_obs%Precip, climate%applied%Precip, region_name)
    
    END IF
    
    ! Clean up after yourself
    CALL deallocate_shared( wdHs_dx_ref)
    CALL deallocate_shared( wdHs_dy_ref)
    CALL deallocate_shared( wPrecip_RL_ref)
    CALL deallocate_shared( wPrecip_RL_mod)
    CALL deallocate_shared( wdPrecip_RL)
    
  END SUBROUTINE run_climate_model_dT_glob
  
  ! Climate matrix with PI + LGM snapshots, forced with CO2 (from record or from inverse routine) from Berends et al., 2018
  SUBROUTINE run_climate_model_matrix_PI_LGM( mesh, ice, SMB, climate, region_name, grid_smooth)
    ! Use CO2 (either prescribed or inversely modelled) to force the 2-snapshot (PI-LGM) climate matrix (Berends et al., 2018)
    
    IMPLICIT NONE

    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    TYPE(type_SMB_model),                INTENT(IN)    :: SMB
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    
    ! Local variables:
    INTEGER                                            :: vi,m
    
    ! Use the (CO2 + absorbed insolation)-based interpolation scheme for temperature
    CALL run_climate_model_matrix_PI_LGM_temperature( mesh, ice, SMB, climate, region_name, grid_smooth)
    
    ! Use the (CO2 + ice-sheet geometry)-based interpolation scheme for precipitation
    CALL run_climate_model_matrix_PI_LGM_precipitation( mesh, ice, climate, region_name, grid_smooth)
      
    ! Safety checks
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
      IF (climate%applied%T2m( vi,m) < 150._dp) THEN
        WRITE(0,*) ' WARNING - run_climate_model_matrix_PI_LGM: excessively low temperatures (<150K) detected!'
      ELSEIF (climate%applied%T2m( vi,m) < 0._dp) THEN
        WRITE(0,*) ' ERROR - run_climate_model_matrix_PI_LGM: negative temperatures (<0K) detected!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      ELSEIF (climate%applied%T2m( vi,m) /= climate%applied%T2m( vi,m)) THEN
        WRITE(0,*) ' ERROR - run_climate_model_matrix_PI_LGM: NaN temperatures  detected!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      ELSEIF (climate%applied%Precip( vi,m) <= 0._dp) THEN
        WRITE(0,*) ' ERROR - run_climate_model_matrix_PI_LGM: zero/negative precipitation detected!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      ELSEIF (climate%applied%Precip( vi,m) /= climate%applied%Precip( vi,m)) THEN
        WRITE(0,*) ' ERROR - run_climate_model_matrix_PI_LGM: NaN precipitation  detected!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
    END DO
    END DO
    CALL sync
    
  END SUBROUTINE run_climate_model_matrix_PI_LGM
  SUBROUTINE run_climate_model_matrix_PI_LGM_temperature( mesh, ice, SMB, climate, region_name, grid_smooth)
    ! The (CO2 + absorbed insolation)-based matrix interpolation for temperature, from Berends et al. (2018)
    
    IMPLICIT NONE

    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    TYPE(type_SMB_model),                INTENT(IN)    :: SMB
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    
    ! Local variables:
    INTEGER                                            :: vi,m
    REAL(dp)                                           :: CO2, w_CO2
    REAL(dp), DIMENSION(:    ), POINTER                ::  w_ins,  w_ins_smooth,  w_ice,  w_tot
    INTEGER                                            :: ww_ins, ww_ins_smooth, ww_ice, ww_tot
    REAL(dp)                                           :: w_ins_av
    REAL(dp), DIMENSION(:,:  ), POINTER                :: T_ref_GCM
    REAL(dp), DIMENSION(:    ), POINTER                :: Hs_ref_GCM, lambda_ref_GCM
    INTEGER                                            :: wT_ref_GCM, wHs_ref_GCM, wlambda_ref_GCM
    
    REAL(dp), PARAMETER                                :: w_cutoff = 0.25_dp        ! Crop weights to [-w_cutoff, 1 + w_cutoff]
    REAL(dp), PARAMETER                                :: P_offset = 0.008_dp       ! Normalisation term in precipitation anomaly to avoid divide-by-nearly-zero
    
    ! Allocate shared memory
    CALL allocate_shared_dp_1D( mesh%nV    , w_ins,          ww_ins         )
    CALL allocate_shared_dp_1D( mesh%nV    , w_ins_smooth,   ww_ins_smooth  )
    CALL allocate_shared_dp_1D( mesh%nV    , w_ice,          ww_ice         )
    CALL allocate_shared_dp_1D( mesh%nV    , w_tot,          ww_tot         )
    CALL allocate_shared_dp_2D( mesh%nV, 12, T_ref_GCM,      wT_ref_GCM     )
    CALL allocate_shared_dp_1D( mesh%nV    , Hs_ref_GCM,     wHs_ref_GCM    )
    CALL allocate_shared_dp_1D( mesh%nV    , lambda_ref_GCM, wlambda_ref_GCM)
    
    ! Find CO2 interpolation weight (use either prescribed or modelled CO2)
    ! =====================================================================
    
    IF (C%choice_forcing_method == 'CO2_direct') THEN
      CO2 = forcing%CO2_obs
    ELSEIF (C%choice_forcing_method == 'd18O_inverse_CO2') THEN
      CO2 = forcing%CO2_mod
    ELSEIF (C%choice_forcing_method == 'd18O_inverse_dT_glob') THEN
      CO2 = 0._dp
      WRITE(0,*) '  ERROR - run_climate_model_matrix_PI_LGM must only be called with the correct forcing method, check your code!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    ELSE
      CO2 = 0._dp
      WRITE(0,*) '  ERROR - choice_forcing_method "', C%choice_forcing_method, '" not implemented in run_climate_model_matrix_PI_LGM!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
    
    w_CO2 = MAX( -w_cutoff, MIN( 1._dp + w_cutoff, (CO2 - 190._dp) / (280._dp - 190._dp) ))   ! Berends et al., 2018 - Eq. 1
    
    ! Find the interpolation weights based on absorbed insolation
    ! ===========================================================
    
    ! Calculate modelled absorbed insolation
    climate%applied%I_abs( mesh%v1:mesh%v2) = 0._dp
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
      climate%applied%I_abs( vi) = climate%applied%I_abs( vi) + climate%applied%Q_TOA( vi,m) * (1._dp - SMB%Albedo( vi,m))  ! Berends et al., 2018 - Eq. 2
    END DO
    END DO
    CALL sync
    
    ! Calculate weighting field
    DO vi = mesh%v1, mesh%v2
      w_ins( vi) = MAX( -w_cutoff, MIN( 1._dp + w_cutoff, (    climate%applied%I_abs( vi) -     climate%GCM_LGM%I_abs( vi)) / &  ! Berends et al., 2018 - Eq. 3
                                                          (    climate%GCM_PI%I_abs(  vi) -     climate%GCM_LGM%I_abs( vi)) ))
    END DO
    CALL sync
    w_ins_av     = MAX( -w_cutoff, MIN( 1._dp + w_cutoff, (SUM(climate%applied%I_abs)     - SUM(climate%GCM_LGM%I_abs)    ) / &
                                                          (SUM(climate%GCM_PI%I_abs )     - SUM(climate%GCM_LGM%I_abs)    ) ))
   
    ! Smooth the weighting field
    w_ins_smooth( mesh%v1:mesh%v2) = w_ins( mesh%v1:mesh%v2)
    CALL smooth_Gaussian_2D( mesh, grid_smooth, w_ins_smooth, 200000._dp)
    !CALL smooth_Shepard_2D( grid, w_ins_smooth, 200000._dp)
    
    ! Combine unsmoothed, smoothed, and regional average weighting fields (Berends et al., 2018, Eq. 4)
    IF (region_name == 'NAM' .OR. region_name == 'EAS') THEN
      w_ice( mesh%v1:mesh%v2) = (1._dp * w_ins(        mesh%v1:mesh%v2) + &
                                 3._dp * w_ins_smooth( mesh%v1:mesh%v2) + &
                                 3._dp * w_ins_av) / 7._dp
    ELSEIF (region_name == 'GRL' .OR. region_name == 'ANT') THEN
      w_ice( mesh%v1:mesh%v2) = (1._dp * w_ins_smooth( mesh%v1:mesh%v2) + &
                                 6._dp * w_ins_av) / 7._dp
    END IF
     
    ! Combine interpolation weights from absorbed insolation and CO2 into the final weights fields
    IF     (region_name == 'NAM' .OR. region_name == 'EAS') THEN
      w_tot( mesh%v1:mesh%v2) = (        w_CO2 + w_ice( mesh%v1:mesh%v2)) / 2._dp  ! Berends et al., 2018 - Eq. 5
    ELSEIF (region_name == 'GRL' .OR. region_name == 'ANT') THEN
      w_tot( mesh%v1:mesh%v2) = (3._dp * w_CO2 + w_ice( mesh%v1:mesh%v2)) / 4._dp  ! Berends et al., 2018 - Eq. 9
    END IF

    ! Interpolate between the GCM snapshots
    ! =====================================
    
    DO vi = mesh%v1, mesh%v2
      
      ! Find matrix-interpolated orography, lapse rate, and temperature
      Hs_ref_GCM(     vi  ) = (w_tot( vi) *  climate%GCM_PI%Hs_ref( vi  )                               ) + ((1._dp - w_tot( vi)) * climate%GCM_LGM%Hs_ref( vi  ))  ! Berends et al., 2018 - Eq. 8
      lambda_ref_GCM( vi  ) = (w_tot( vi) *  climate%GCM_PI%lambda( vi  )                               ) + ((1._dp - w_tot( vi)) * climate%GCM_LGM%lambda( vi  ))  ! Not listed in the article, shame on me!
      T_ref_GCM(      vi,:) = (w_tot( vi) * (climate%GCM_PI%T2m(    vi,:) - climate%GCM_bias_T2m( vi,:))) + ((1._dp - w_tot( vi)) * climate%GCM_LGM%T2m(    vi,:))  ! Berends et al., 2018 - Eq. 6
     !T_ref_GCM(      vi,:) = (w_tot( vi) *  climate%GCM_PI%T2m(    vi,:)                               ) + ((1._dp - w_tot( vi)) * climate%GCM_LGM%T2m(    vi,:))  ! Berends et al., 2018 - Eq. 6
    
      ! Adapt temperature to model orography using matrix-derived lapse-rate
      DO m = 1, 12
        climate%applied%T2m( vi,m) = T_ref_GCM( vi,m) - lambda_ref_GCM( vi) * (ice%Hs( vi) - Hs_ref_GCM( vi))  ! Berends et al., 2018 - Eq. 11
      END DO
      
!      ! Correct for GCM bias
!      climate%applied%T2m( vi,:) = climate%applied%T2m( vi,:) - climate%GCM_bias_T2m( vi,:)
    
    END DO
    CALL sync 
   
    ! Clean up after yourself
    CALL deallocate_shared( ww_ins)
    CALL deallocate_shared( ww_ins_smooth)
    CALL deallocate_shared( ww_ice)
    CALL deallocate_shared( ww_tot)
    CALL deallocate_shared( wT_ref_GCM)
    CALL deallocate_shared( wHs_ref_GCM)
    CALL deallocate_shared( wlambda_ref_GCM)
    
  END SUBROUTINE run_climate_model_matrix_PI_LGM_temperature
  SUBROUTINE run_climate_model_matrix_PI_LGM_precipitation( mesh, ice, climate, region_name, grid_smooth)
    ! The (CO2 + ice geometry)-based matrix interpolation for precipitation, from Berends et al. (2018)
    ! For NAM and EAS, this is based on local ice geometry and uses the Roe&Lindzen precipitation model for downscaling.
    ! For GRL and ANT, this is based on total ice volume,  and uses the simple CC   precipitation model for downscaling.
    ! The rationale for this difference is that glacial-interglacial differences in ice geometry are much more
    ! dramatic in NAM and EAS than they are in GRL and ANT.
    
    IMPLICIT NONE

    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    TYPE(type_ice_model),                INTENT(IN)    :: ice
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    
    ! Local variables:
    INTEGER                                            :: vi
    REAL(dp), DIMENSION(:    ), POINTER                ::  w_PD,  w_LGM
    INTEGER                                            :: ww_PD, ww_LGM
    REAL(dp)                                           :: w_tot
    REAL(dp), DIMENSION(:,:  ), POINTER                :: T_ref_GCM, P_ref_GCM
    REAL(dp), DIMENSION(:    ), POINTER                :: lambda_GCM, Hs_GCM, Hs_ref_GCM
    INTEGER                                            :: wT_ref_GCM, wP_ref_GCM, wlambda_GCM, wHs_GCM, wHs_ref_GCM
    
    REAL(dp), PARAMETER                                :: w_cutoff = 0.25_dp        ! Crop weights to [-w_cutoff, 1 + w_cutoff]
    
    ! Allocate shared memory
    CALL allocate_shared_dp_1D( mesh%nV    , w_PD,           ww_PD          )
    CALL allocate_shared_dp_1D( mesh%nV    , w_LGM,          ww_LGM         )
    CALL allocate_shared_dp_2D( mesh%nV, 12, T_ref_GCM,      wT_ref_GCM     )
    CALL allocate_shared_dp_2D( mesh%nV, 12, P_ref_GCM,      wP_ref_GCM     )
    CALL allocate_shared_dp_1D( mesh%nV    , lambda_GCM,     wlambda_GCM    )
    CALL allocate_shared_dp_1D( mesh%nV    , Hs_GCM,         wHs_GCM        )
    CALL allocate_shared_dp_1D( mesh%nV    , Hs_ref_GCM,     wHs_ref_GCM    )
    
    ! Calculate interpolation weights based on ice geometry
    ! =====================================================
    
    ! First calculate the total ice volume term (second term in the equation)
    w_tot = MAX(-w_cutoff, MIN(1._dp + w_cutoff, (SUM(ice%Hi) - SUM(climate%GCM_PI%Hi)) / (SUM(climate%GCM_LGM%Hi) - SUM(climate%GCM_PI%Hi)) ))
    
    IF (region_name == 'NAM' .OR. region_name == 'EAS') THEN
      ! Combine total + local ice thicness; Berends et al., 2018, Eq. 12
    
      ! Then the local ice thickness term
      DO vi = mesh%v1, mesh%v2
        
        IF (climate%GCM_PI%Hi( vi) == 0.1_dp) THEN
          IF (climate%GCM_LGM%Hi( vi) == 0.1_dp) THEN
            ! No ice in any GCM state. Use only total ice volume.
            w_LGM( vi) = MAX(-0.25_dp, MIN(1.25_dp, w_tot ))
            w_PD(  vi) = 1._dp - w_LGM( vi)
          ELSE
            ! No ice at PD, ice at LGM. Linear inter- / extrapolation.
            w_LGM( vi) = MAX(-0.25_dp, MIN(1.25_dp, ((ice%Hi( vi) - 0.1_dp) / (climate%GCM_LGM%Hi( vi) - 0.1_dp)) * w_tot ))
            w_PD(  vi) = 1._dp - w_LGM( vi)  
          END IF
        ELSE
          ! Ice in both GCM states.  Linear inter- / extrapolation
          w_LGM( vi) = MAX(-0.25_dp, MIN(1.25_dp, ((ice%Hi( vi) - 0.1_dp) / (climate%GCM_LGM%Hi( vi) - 0.1_dp)) * w_tot ))
          w_PD(  vi) = 1._dp - w_LGM( vi)
        END IF 
        
      END DO
      CALL sync
      
      w_LGM( mesh%v1:mesh%v2) = w_LGM( mesh%v1:mesh%v2) * w_tot
      
      ! Smooth the weighting field
      CALL smooth_Gaussian_2D( mesh, grid_smooth, w_LGM, 200000._dp) 
      !CALL smooth_Shepard_2D( grid, w_LGM, 200000._dp)
      
      w_PD( mesh%v1:mesh%v2) = 1._dp - w_LGM( mesh%v1:mesh%v2) 
      
    ELSEIF (region_name == 'GRL' .OR. region_name == 'ANT') THEN
      ! Use only total ice volume and CO2; Berends et al., 2018, Eq. 13
    
      w_LGM( mesh%v1:mesh%v2) = w_tot
      w_PD(  mesh%v1:mesh%v2) = 1._dp - w_LGM( mesh%v1:mesh%v2)
      
    END IF
        
    ! Interpolate the GCM snapshots
    ! =============================
    
    DO vi = mesh%v1, mesh%v2
      
      T_ref_GCM(  vi,:) =      (w_PD( vi) *     (climate%GCM_PI%T2m(    vi,:) - climate%GCM_bias_T2m(   vi,:)))  + (w_LGM( vi) *     climate%GCM_LGM%T2m(    vi,:))   ! Berends et al., 2018 - Eq. 6
      lambda_GCM( vi  ) =      (w_PD( vi) *      climate%GCM_PI%lambda( vi  )                                 )  + (w_LGM( vi) *     climate%GCM_LGM%lambda( vi  ))
      Hs_GCM(     vi  ) =      (w_PD( vi) *      climate%GCM_PI%Hs(     vi  )                                 )  + (w_LGM( vi) *     climate%GCM_LGM%Hs(     vi  ))   ! Berends et al., 2018 - Eq. 8
      Hs_ref_GCM( vi  ) =      (w_PD( vi) *      climate%GCM_PI%Hs_ref( vi  )                                 )  + (w_LGM( vi) *     climate%GCM_LGM%Hs_ref( vi  ))
     !P_ref_GCM(  vi,:) = EXP( (w_PD( vi) *  LOG(climate%GCM_PI%Precip( vi,:) / climate%GCM_bias_Precip( vi,:))) + (w_LGM( vi) * LOG(climate%GCM_LGM%Precip( vi,:)))) ! Berends et al., 2018 - Eq. 7
     
      P_ref_GCM(  vi,:) = EXP( (w_PD( vi) *  LOG(climate%GCM_PI%Precip( vi,:)                                  )) + (w_LGM( vi) * LOG(climate%GCM_LGM%Precip( vi,:)))) ! Berends et al., 2018 - Eq. 7
      P_ref_GCM(  vi,:) = P_ref_GCM( vi,:) / (1._dp + (w_PD( vi) * (climate%GCM_bias_Precip( vi,:) - 1._dp)))
      
      P_ref_GCM(  vi,:) = EXP( (w_PD( vi) *  LOG(climate%GCM_PI%Precip( vi,:)                                  )) + (w_LGM( vi) * LOG(climate%GCM_LGM%Precip( vi,:)))) ! Berends et al., 2018 - Eq. 7
      
!      ! Correct for GCM bias
!      P_ref_GCM( vi,:) = P_ref_GCM( vi,:) / climate%GCM_bias_Precip( vi,:)
      
    END DO
    CALL sync
    
    ! Downscale precipitation from the coarse-resolution reference
    ! GCM orography to the fine-resolution ice-model orography
    ! ========================================================
    
    IF (region_name == 'NAM' .OR. region_name == 'EAS') THEN
      ! Use the Roe&Lindzen precipitation model to do this; Berends et al., 2018, Eqs. A3-A7
      CALL adapt_precip_Roe( mesh, ice%Hs, Hs_GCM, Hs_ref_GCM, lambda_GCM, T_ref_GCM, P_ref_GCM, ice%dHs_dx, ice%dHs_dy, climate%PD_obs%Wind_LR, climate%PD_obs%Wind_DU, climate%applied%Precip)
    ELSEIF (region_name == 'GRL' .OR. region_name == 'ANT') THEN
      ! Use a simpler temperature-based correction; Berends et al., 2018, Eq. 14
      CALL adapt_precip_CC( mesh, ice%Hs, Hs_ref_GCM, T_ref_GCM, P_ref_GCM, climate%applied%Precip, region_name)
    END IF
   
    ! Clean up after yourself
    CALL deallocate_shared( ww_PD)
    CALL deallocate_shared( ww_LGM)
    CALL deallocate_shared( wT_ref_GCM)
    CALL deallocate_shared( wP_ref_GCM)
    CALL deallocate_shared( wlambda_GCM)
    CALL deallocate_shared( wHs_GCM)
    CALL deallocate_shared( wHs_ref_GCM)
    
  END SUBROUTINE run_climate_model_matrix_PI_LGM_precipitation
  
  ! Two different parameterised precipitation models:
  ! - a simply Clausius-Clapeyron-based method, used for GRL and ANT
  ! - the Roe & Lindzen temperature/orography-based model, used for NAM and EAS
  SUBROUTINE adapt_precip_CC(  mesh, Hs, Hs_ref_GCM, T_ref_GCM, P_ref_GCM, Precip_GCM, region_name)
    
    USE parameters_module, ONLY: T0
     
    IMPLICIT NONE
    
    ! Input variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: Hs              ! Model orography (m)
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: Hs_ref_GCM      ! Reference orography (m)           - total ice-weighted
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: T_ref_GCM       ! Reference temperature (K)         - total ice-weighted
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: P_ref_GCM       ! Reference precipitation (m/month) - total ice-weighted
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name

    ! Output variables:         
    REAL(dp), DIMENSION(:,:  ),          INTENT(OUT)   :: Precip_GCM      ! Climate matrix precipitation
    
    ! Local variables
    INTEGER                                            :: vi,m
    REAL(dp), DIMENSION(:,:  ), POINTER                ::  T_inv,  T_inv_ref
    INTEGER                                            :: wT_inv, wT_inv_ref
    
    ! Allocate shared memory
    CALL allocate_shared_dp_2D( mesh%nV, 12, T_inv,     wT_inv    )
    CALL allocate_shared_dp_2D( mesh%nV, 12, T_inv_ref, wT_inv_ref)
    
    ! Calculate inversion layer temperatures
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
      T_inv_ref( vi,m) = 88.9_dp + 0.67_dp *  T_ref_GCM( vi,m)
      T_inv(     vi,m) = 88.9_dp + 0.67_dp * (T_ref_GCM( vi,m) - 0.008_dp * (Hs( vi) - Hs_ref_GCM( vi)))
    END DO
    END DO
    CALL sync

    IF     (region_name == 'GRL') THEN
      ! Method of Jouzel and Merlivat (1984), see equation (4.82) in Huybrechts (1992)
    
      DO vi = mesh%v1, mesh%v2
      DO m = 1, 12
        Precip_GCM( vi,m) = P_ref_GCM( vi,m) * 1.04**(T_inv( vi,m) - T_inv_ref( vi,m))
      END DO
      END DO
      CALL sync
    
    ELSEIF (region_name == 'ANT') THEN
      ! As with Lorius/Jouzel method (also Huybrechts, 2002
    
      DO vi = mesh%v1, mesh%v2
      DO m = 1, 12
        Precip_GCM( vi,m) = P_ref_GCM( vi,m) * (T_inv_ref( vi,m) / T_inv( vi,m))**2 * EXP(22.47_dp * (T0 / T_inv_ref( vi,m) - T0 / T_inv( vi,m)))
      END DO
      END DO
      CALL sync
      
    ELSE
      IF (par%master) WRITE(0,*) '  ERROR - adapt_precip_CC should only be used for Greenland and Antarctica!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
    
    ! Clean up after yourself
    CALL deallocate_shared( wT_inv)
    CALL deallocate_shared( wT_inv_ref)
    
  END SUBROUTINE adapt_precip_CC
  SUBROUTINE adapt_precip_Roe( mesh, Hs, Hs_GCM, Hs_ref_GCM, lambda_GCM, T_ref_GCM, P_ref_GCM, dHs_dx, dHs_dy, Wind_LR, Wind_DU, Precip_GCM)
     
    IMPLICIT NONE
    
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: Hs
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: Hs_GCM
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: Hs_ref_GCM
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: lambda_GCM
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: T_ref_GCM
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: P_ref_GCM
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: dHs_dx
    REAL(dp), DIMENSION(:    ),          INTENT(IN)    :: dHs_dy
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: Wind_LR
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: Wind_DU
    REAL(dp), DIMENSION(:,:  ),          INTENT(OUT)   :: Precip_GCM
    
    ! Local variables:
    INTEGER                                            :: vi,m
    REAL(dp), DIMENSION(:    ), POINTER                ::  dHs_dx_GCM,  dHs_dy_GCM
    INTEGER                                            :: wdHs_dx_GCM, wdHs_dy_GCM
    REAL(dp), DIMENSION(:,:  ), POINTER                ::  T_mod,  P_RL_ref_GCM,  P_RL_mod,  dP_RL
    INTEGER                                            :: wT_mod, wP_RL_ref_GCM, wP_RL_mod, wdP_RL
    
    ! Allocate shared memory
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dx_GCM,     wdHs_dx_GCM    )
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dy_GCM,     wdHs_dy_GCM    )
    CALL allocate_shared_dp_2D( mesh%nV, 12, T_mod,          wT_mod         )
    CALL allocate_shared_dp_2D( mesh%nV, 12, P_RL_ref_GCM,   wP_RL_ref_GCM  )
    CALL allocate_shared_dp_2D( mesh%nV, 12, P_RL_mod,       wP_RL_mod      )
    CALL allocate_shared_dp_2D( mesh%nV, 12, dP_RL,          wdP_RL         )
    
    ! Get the surface slopes of the coarse-resolution reference GCM orography
    CALL get_mesh_derivatives( mesh, Hs_GCM, dHs_dx_GCM, dHs_dy_GCM)
    
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
    
      T_mod( vi,m) = T_ref_GCM( vi,m) - lambda_GCM( vi) * (Hs( vi) - Hs_ref_GCM( vi))
    
      ! Calculate RL precipitation for the matrix-interpolated GCM reference state
      CALL precipitation_model_Roe( T_ref_GCM( vi,m), dHs_dx_GCM( vi), dHs_dy_GCM( vi), Wind_LR( vi,m), Wind_DU( vi,m), P_RL_ref_GCM( vi,m))
      
      ! Calculate RL precipitation for the actual ice model state
      CALL precipitation_model_Roe( T_mod(     vi,m), dHs_dx(     vi), dHs_dy(     vi), Wind_LR( vi,m), Wind_DU( vi,m), P_RL_mod(     vi,m))
      
      ! Ratio between those two
      dP_RL( vi,m) = MIN( 2._dp, P_RL_mod( vi,m) / P_RL_ref_GCM( vi,m))
      
      ! Applied model precipitation = (matrix-interpolated GCM reference precipitation) * RL ratio
      Precip_GCM( vi,m) = P_ref_GCM( vi,m) * dP_RL( vi,m)
      
    END DO
    END DO
    CALL sync
   
    ! Clean up after yourself
    CALL deallocate_shared( wdHs_dx_GCM)
    CALL deallocate_shared( wdHs_dy_GCM)
    CALL deallocate_shared( wT_mod)
    CALL deallocate_shared( wP_RL_ref_GCM)
    CALL deallocate_shared( wP_RL_mod)
    CALL deallocate_shared( wdP_RL)
    
  END SUBROUTINE adapt_precip_Roe
  SUBROUTINE precipitation_model_Roe( T2m, dHs_dx, dHs_dy, Wind_LR, Wind_DU, Precip)
    ! Precipitation model of Roe (J. Glac, 2002), integration from Roe and Lindzen (J. Clim. 2001)
    
    USE parameters_module, ONLY: T0, pi, sec_per_year
    
    ! In/output variables:
    REAL(dp),                            INTENT(IN)    :: T2m                  ! 2-m air temperature [K]
    REAL(dp),                            INTENT(IN)    :: dHs_dx               ! Surface slope in the x-direction [m/m]
    REAL(dp),                            INTENT(IN)    :: dHs_dy               ! Surface slope in the y-direction [m/m]
    REAL(dp),                            INTENT(IN)    :: Wind_LR              ! Wind speed    in the x-direction [m/s]
    REAL(dp),                            INTENT(IN)    :: Wind_DU              ! Wind speed    in the y-direction [m/s]
    REAL(dp),                            INTENT(OUT)   :: Precip               ! Modelled precipitation

    ! Local variables:
    REAL(dp)                                           :: upwind_slope         ! Upwind slope
    REAL(dp)                                           :: E_sat                ! Saturation vapour pressure as function of temperature [Pa]
    REAL(dp)                                           :: x0                   ! Integration parameter x0 [m s-1]
    REAL(dp)                                           :: err_in,err_out
    
    REAL(dp), PARAMETER                                :: e_sat0  = 611.2_dp   ! Saturation vapour pressure at 273.15 K [Pa]
    REAL(dp), PARAMETER                                :: c_one   = 17.67_dp   ! Constant c1 []
    REAL(dp), PARAMETER                                :: c_two   = 243.5_dp   ! Constant c2 [Celcius]

    REAL(dp), PARAMETER                                :: a_par   = 2.5E-11_dp ! Constant a [m2 s  kg-1] (from Roe et al., J. Clim. 2001)
    REAL(dp), PARAMETER                                :: b_par   = 5.9E-09_dp ! Constant b [m  s2 kg-1] (from Roe et al., J. Clim. 2001)
    REAL(dp), PARAMETER                                :: alpha   = 100.0_dp   ! Constant alpha [s m-1]
    
    ! Calculate the upwind slope
    upwind_slope = MAX(0._dp, Wind_LR * dHs_dx + Wind_DU * dHs_dy)

    ! Calculate the saturation vapour pressure E_sat:
    E_sat = e_sat0 * EXP( c_one * (T2m - T0) / (c_two + T2m - T0) )
   
    ! Calculate integration parameter x0 = a/b + w (with w = wind times slope)
    x0 = a_par / b_par + upwind_slope
    
    ! Calculate the error function (2nd term on the r.h.s.)
    err_in = alpha * ABS(x0)
    CALL error_function(err_in,err_out)
    
    ! Calculate precipitation rate as in Appendix of Roe et al. (J. Clim, 2001)
    Precip = ( b_par * E_sat ) * ( x0 / 2._dp + x0**2 * err_out / (2._dp * ABS(x0)) + &
                                         EXP (-alpha**2 * x0**2) / (2._dp * SQRT(pi) * alpha) ) * sec_per_year
        
  END SUBROUTINE precipitation_model_Roe
  
  ! Temperature parameterisation for the EISMINT experiments
  SUBROUTINE EISMINT_climate( mesh, ice, climate, time)
    ! Simple lapse-rate temperature parameterisation
    
    USe parameters_module,           ONLY: pi
    
    IMPLICIT NONE

    TYPE(type_mesh),                     INTENT(IN)    :: mesh   
    TYPE(type_ice_model),                INTENT(IN)    :: ice 
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    REAL(dp),                            INTENT(IN)    :: time
    
    REAL(dp), PARAMETER                                :: lambda = -0.010_dp
    
    INTEGER                                            :: vi, m
    REAL(dp)                                           :: dT_lapse, d, dT
    
    ! Set precipitation to zero - SMB is parameterised anyway...
    climate%applied%Precip(mesh%v1:mesh%v2,:) = 0._dp
    
    ! Surface temperature for fixed or moving margin experiments
    IF     (C%choice_benchmark_experiment == 'EISMINT_1' .OR. &
            C%choice_benchmark_experiment == 'EISMINT_2' .OR. &
            C%choice_benchmark_experiment == 'EISMINT_3') THEN
      ! Moving margin
          
      DO vi = mesh%v1, mesh%v2    
      
        dT_lapse = ice%Hs(vi) * lambda
          
        DO m = 1, 12
          climate%applied%T2m(vi,m) = 270._dp + dT_lapse
        END DO
      END DO
      
    ELSEIF (C%choice_benchmark_experiment == 'EISMINT_4' .OR. &
            C%choice_benchmark_experiment == 'EISMINT_5' .OR. &
            C%choice_benchmark_experiment == 'EISMINT_6') THEN
      ! Fixed margin
    
      DO vi = mesh%v1, mesh%v2    
        d = MAX( ABS(mesh%V(vi,1)/1000._dp), ABS(mesh%V(vi,2)/1000._dp))
    
        DO m = 1, 12
          climate%applied%T2m(vi,m) = 239._dp + (8.0E-08_dp * d**3)
        END DO
      END DO
      
    END IF
    CALL sync
    
    ! Glacial cycles
    IF     (C%choice_benchmark_experiment == 'EISMINT_2' .OR. &
            C%choice_benchmark_experiment == 'EISMINT_5') THEN
      IF (time > 0._dp) THEN
        dT = 10._dp * SIN(2 * pi * time / 20000._dp)
        DO vi = mesh%v1, mesh%v2 
          climate%applied%T2m(vi,:) = climate%applied%T2m(vi,:) + dT
        END DO
      END IF
    ELSEIF (C%choice_benchmark_experiment == 'EISMINT_3' .OR. &
            C%choice_benchmark_experiment == 'EISMINT_6') THEN
      IF (time > 0._dp) THEN
        dT = 10._dp * SIN(2 * pi * time / 40000._dp)
        DO vi = mesh%v1, mesh%v2 
          climate%applied%T2m(vi,:) = climate%applied%T2m(vi,:) + dT
        END DO
      END IF
    END IF
    CALL sync
    
  END SUBROUTINE EISMINT_climate
  
  ! Initialising the region-specific climate model, containing all the subclimates
  ! (PD observations, GCM snapshots and the applied climate) on the mesh
  SUBROUTINE initialise_climate_model( climate, matrix, mesh, PD, region_name, mask_noice, grid_smooth)
    ! Allocate shared memory for the regional climate models, containing the PD observed,
    ! GCM snapshots and applied climates as "subclimates"
    
    IMPLICIT NONE
    
    ! In/output variables:
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    TYPE(type_climate_matrix),           INTENT(IN)    :: matrix
    TYPE(type_mesh),                     INTENT(INOUT) :: mesh
    TYPE(type_PD_data_fields),           INTENT(IN)    :: PD
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    INTEGER,  DIMENSION(:    ),          INTENT(IN)    :: mask_noice
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    
    ! Local variables:
    CHARACTER(LEN=64), PARAMETER                       :: routine_name = 'initialise_climate_model'
    INTEGER                                            :: n1, n2
    
    n1 = par%mem%n
    
    IF (par%master) WRITE (0,*) '  Initialising climate model...'
    
    ! Exceptions for benchmark experiments
    IF (C%do_benchmark_experiment) THEN
      IF (C%choice_benchmark_experiment == 'EISMINT_1' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_2' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_3' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_4' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_5' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_6' .OR. &
          C%choice_benchmark_experiment == 'Halfar' .OR. &
          C%choice_benchmark_experiment == 'Bueler' .OR. &
          C%choice_benchmark_experiment == 'MISMIP_mod'.OR. &
          C%choice_benchmark_experiment == 'mesh_generation_test') THEN
          
        ! Entirely parameterised climate
        CALL allocate_subclimate( mesh, climate%applied, 'applied')
        CALL allocate_subclimate( mesh, climate%PD_obs,  'none')
        CALL allocate_subclimate( mesh, climate%GCM_PI,  'none')
        CALL allocate_subclimate( mesh, climate%GCM_LGM, 'none')
        RETURN
        
      ELSE
        IF (par%master) WRITE(0,*) '  ERROR: benchmark experiment "', TRIM(C%choice_benchmark_experiment), '" not implemented in initialise_climate_model!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
    END IF ! IF (C%do_benchmark_experiment) THEN
    
    ! Initialise data structures for the regional ERA40 climate and the final applied climate
    CALL allocate_subclimate( mesh, climate%PD_obs,   'ERA40'  )
    CALL allocate_subclimate( mesh, climate%applied,  'applied')
    
    ! Map these subclimates from global mesh to model mesh
    CALL map_subclimate_to_mesh( mesh,  matrix%PD_obs,  climate%PD_obs)
    
    ! The differenct GCM snapshots 
    IF (C%choice_forcing_method == 'd18O_inverse_dT_glob') THEN
      ! This choice of forcing doesn't use any GCM data
      
      CALL allocate_subclimate( mesh, climate%GCM_PI,  'none')
      CALL allocate_subclimate( mesh, climate%GCM_LGM, 'none')
      
    ELSEIF (C%choice_forcing_method == 'CO2_direct' .OR. C%choice_forcing_method == 'd18O_inverse_CO2') THEN
      ! These two choices use the climate matrix
      
      IF (C%choice_climate_matrix == 'PI_LGM') THEN
      
        ! Initialise data structures for the GCM snapshots
        CALL allocate_subclimate( mesh, climate%GCM_PI,   'HadCM3_PI' )
        CALL allocate_subclimate( mesh, climate%GCM_LGM,  'HadCM3_LGM')
        
        ! Map these subclimates from global mesh to model mesh
        CALL map_subclimate_to_mesh( mesh,  matrix%GCM_PI,  climate%GCM_PI )
        CALL map_subclimate_to_mesh( mesh,  matrix%GCM_LGM, climate%GCM_LGM)
        
        ! Right now, no wind is read from GCM output; just use PD observations everywhere
        climate%GCM_PI%Wind_WE(  mesh%v1:mesh%v2,:) = climate%PD_obs%Wind_WE( mesh%v1:mesh%v2,:)
        climate%GCM_PI%Wind_SN(  mesh%v1:mesh%v2,:) = climate%PD_obs%Wind_SN( mesh%v1:mesh%v2,:)
        climate%GCM_LGM%Wind_WE( mesh%v1:mesh%v2,:) = climate%PD_obs%Wind_WE( mesh%v1:mesh%v2,:)
        climate%GCM_LGM%Wind_SN( mesh%v1:mesh%v2,:) = climate%PD_obs%Wind_SN( mesh%v1:mesh%v2,:)
        
        ! Initialise the ICE5G geometries for these two snapshots
        CALL initialise_subclimate_ICE5G_geometry( mesh, climate%GCM_PI,  PD, matrix%ICE5G_PD,  matrix%ICE5G_PD, mask_noice)
        CALL initialise_subclimate_ICE5G_geometry( mesh, climate%GCM_LGM, PD, matrix%ICE5G_LGM, matrix%ICE5G_PD, mask_noice)
        
        ! Calculate spatially variable lapse rate
        climate%GCM_PI%lambda = 0.008_dp
        IF     (region_name == 'NAM' .OR. region_name == 'EAS') THEN
          CALL initialise_subclimate_spatially_variable_lapserate( mesh, grid_smooth, climate%GCM_LGM, climate%GCM_PI)
        ELSEIF (region_name == 'GLR' .OR. region_name == 'ANT') THEN
          climate%GCM_LGM%lambda = 0.008_dp
        END IF
    
        ! Calculate GCM climate bias
        CALL initialise_climate_model_GCM_bias( mesh, climate)
        
        ! Get reference absorbed insolation for the GCM snapshots
        CALL initialise_subclimate_absorbed_insolation( mesh, climate%GCM_PI , region_name, mask_noice, climate%GCM_bias_T2m, climate%GCM_bias_Precip)
        CALL initialise_subclimate_absorbed_insolation( mesh, climate%GCM_LGM, region_name, mask_noice, climate%GCM_bias_T2m, climate%GCM_bias_Precip)
        
      ELSE
        IF (par%master) WRITE(0,*) '  ERROR: choice_climate_matrix "', TRIM(C%choice_climate_matrix), '" not implemented in initialise_climate_model!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
      
    ELSE
      IF (par%master) WRITE(0,*) '  ERROR: choice_forcing_method "', TRIM(C%choice_forcing_method), '" not implemented in initialise_climate_model!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
  
    ! Initialise applied climate with present-day observations
    IF (par%master) THEN
      climate%applied%T2m     = climate%PD_obs%T2m
      climate%applied%Precip  = climate%PD_obs%Precip
      climate%applied%Hs      = climate%PD_obs%Hs
      climate%applied%Wind_LR = climate%PD_obs%Wind_LR
      climate%applied%Wind_DU = climate%PD_obs%Wind_DU
    END IF ! IF (par%master) THEN
    CALL sync
    
    n2 = par%mem%n
    CALL write_to_memory_log( routine_name, n1, n2)
  
  END SUBROUTINE initialise_climate_model  
  SUBROUTINE allocate_subclimate( mesh, subclimate, name)
    ! Allocate shared memory for a "subclimate" (PD observed, GCM snapshot or applied climate) on the mesh
    
    IMPLICIT NONE
    
    TYPE(type_mesh),                     INTENT(IN)    :: mesh  
    TYPE(type_subclimate_region),        INTENT(INOUT) :: subclimate
    CHARACTER(LEN=*),                    INTENT(IN)    :: name
    
    subclimate%name = name
    
    ! If this snapshot is not used, don't allocate any memory
    IF (name == 'none') RETURN
    
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%T2m,            subclimate%wT2m           )
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Precip,         subclimate%wPrecip        )
    CALL allocate_shared_dp_1D( mesh%nV,     subclimate%Hs_ref,         subclimate%wHs_ref        )
    CALL allocate_shared_dp_1D( mesh%nV,     subclimate%Hi,             subclimate%wHi            )
    CALL allocate_shared_dp_1D( mesh%nV,     subclimate%Hb,             subclimate%wHb            )
    CALL allocate_shared_dp_1D( mesh%nV,     subclimate%Hs,             subclimate%wHs            )
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Wind_WE,        subclimate%wWind_WE       )
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Wind_SN,        subclimate%wWind_SN       )
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Wind_LR,        subclimate%wWind_LR       )
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Wind_DU,        subclimate%wWind_DU       )
      
    CALL allocate_shared_dp_0D(              subclimate%CO2,            subclimate%wCO2           )
    CALL allocate_shared_dp_0D(              subclimate%orbit_time,     subclimate%worbit_time    )
    CALL allocate_shared_dp_0D(              subclimate%orbit_ecc,      subclimate%worbit_ecc     )
    CALL allocate_shared_dp_0D(              subclimate%orbit_obl,      subclimate%worbit_obl     )
    CALL allocate_shared_dp_0D(              subclimate%orbit_pre,      subclimate%worbit_pre     )
    CALL allocate_shared_dp_0D(              subclimate%sealevel,       subclimate%wsealevel      )
    
    CALL allocate_shared_dp_1D( mesh%nV,     subclimate%lambda,         subclimate%wlambda        )
    
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Q_TOA,          subclimate%wQ_TOA         )
    CALL allocate_shared_dp_2D( mesh%nV, 12, subclimate%Albedo,         subclimate%wAlbedo        )
    CALL allocate_shared_dp_1D( mesh%nV,     subclimate%I_abs,          subclimate%wI_abs         )
    CALL allocate_shared_dp_0D(              subclimate%Q_TOA_jun_65N,  subclimate%wQ_TOA_jun_65N )
    CALL allocate_shared_dp_0D(              subclimate%Q_TOA_jan_80S,  subclimate%wQ_TOA_jan_80S )
    
    CALL allocate_shared_dp_0D(              subclimate%T_ocean_mean,   subclimate%wT_ocean_mean  )
    
  END SUBROUTINE allocate_subclimate
  SUBROUTINE initialise_climate_model_GCM_bias( mesh, climate)
    ! Calculate the GCM climate bias
     
    IMPLICIT NONE
      
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh  
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    
    ! Local variables:
    INTEGER                                            :: vi
    REAL(dp), PARAMETER                                :: P_offset = 0.008_dp       ! Normalisation term in precipitation anomaly to avoid divide-by-nearly-zero
    
    CALL allocate_shared_dp_2D( mesh%nV, 12, climate%GCM_bias_T2m,    climate%wGCM_bias_T2m   )
    CALL allocate_shared_dp_2D( mesh%nV, 12, climate%GCM_bias_Precip, climate%wGCM_bias_Precip)
    
    DO vi = mesh%v1, mesh%v2
      
      climate%GCM_bias_T2m(    vi,:) =  climate%GCM_PI%T2m(    vi,:)             -  climate%PD_obs%T2m(    vi,:)
      climate%GCM_bias_Precip( vi,:) = (climate%GCM_PI%Precip( vi,:) + P_offset) / (climate%PD_obs%Precip( vi,:) + P_offset)
      
    END DO
    CALL sync
    
  END SUBROUTINE initialise_climate_model_GCM_bias
  SUBROUTINE initialise_subclimate_ICE5G_geometry( mesh, snapshot, PD, ICE5G, ICE5G_PD, mask_noice)
    ! Initialise the GCM snapshot's corresponding ICE5G geometry (which is available at higher resolution than from the GCM itself)
     
    IMPLICIT NONE
      
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh  
    TYPE(type_subclimate_region),        INTENT(INOUT) :: snapshot
    TYPE(type_PD_data_fields),           INTENT(IN)    :: PD
    TYPE(type_ICE5G_timeframe),          INTENT(IN)    :: ICE5G
    TYPE(type_ICE5G_timeframe),          INTENT(IN)    :: ICE5G_PD
    INTEGER,  DIMENSION(:    ),          INTENT(IN)    :: mask_noice
    
    ! Local variables:
    INTEGER                                            :: vi
    REAL(dp), DIMENSION(:    ), POINTER                ::  Hi_ICE5G,  Hb_ICE5G,  Hb_ICE5G_PD,  mask_ice_ICE5G,  dHb_ICE5G
    INTEGER                                            :: wHi_ICE5G, wHb_ICE5G, wHb_ICE5G_PD, wmask_ice_ICE5G, wdHb_ICE5G
    TYPE(type_remapping_latlon2mesh)                   :: map
    
    ! Downscale the GCM snapshot from the (coarse) GCM geometry to the (fine) ISM geometry
    ! Store the downscaled climate in temporary memory.
    ! ====================================================================================
    
    ! Allocate temporary shared memory
    CALL allocate_shared_dp_1D(     mesh%nV, Hi_ICE5G,       wHi_ICE5G      )
    CALL allocate_shared_dp_1D(     mesh%nV, Hb_ICE5G,       wHb_ICE5G      )
    CALL allocate_shared_dp_1D(     mesh%nV, Hb_ICE5G_PD,    wHb_ICE5G_PD   )
    CALL allocate_shared_dp_1D(     mesh%nV, mask_ice_ICE5G, wmask_ice_ICE5G)
    CALL allocate_shared_dp_1D(     mesh%nV, dHb_ICE5G,      wdHb_ICE5G     )
    
    ! Get mapping arrays
    CALL create_remapping_arrays_glob_mesh( mesh, ICE5G%grid, map)
    
    ! First, map the two ICE5G timeframes to the model grid
    CALL map_latlon2mesh_2D( mesh, map, ICE5G%Hi,       Hi_ICE5G)
    CALL map_latlon2mesh_2D( mesh, map, ICE5G%Hb,       Hb_ICE5G)
    CALL map_latlon2mesh_2D( mesh, map, ICE5G_PD%Hb,    Hb_ICE5G_PD)
    CALL map_latlon2mesh_2D( mesh, map, ICE5G%mask_ice, mask_ice_ICE5G)
    
    ! Deallocate mapping arrays
    CALL deallocate_remapping_arrays_glob_mesh( map)
      
    ! Define sea level (no clear way to do this automatically)
    snapshot%sealevel = 0._dp
    IF      (ICE5G%time == 0._dp) THEN
      snapshot%sealevel = 0._dp
    ELSEIF (ICE5G%time == -120000._dp) THEN
      snapshot%sealevel = -120._dp
    ELSE
      IF (par%master) WRITE(0,*) '   ERROR - need to define a sea level for ICE5G timeframe at t = ', ICE5G%time
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
    
    ! Find the GCM and ISM geometry
    DO vi = mesh%v1, mesh%v2
      
      ! Calculate the ICE5G GIA bedrock deformation for this timeframe
      dHb_ICE5G( vi) = Hb_ICE5G( vi) - Hb_ICE5G_PD( vi)
      
      ! Define the ISM geometry as: PD bedrock + ICE5G GIA signal, ice surface equal to GCM ice surface, ice mask equal to ICE5G ice mask
      ! (seems a little convoluted, but this is how it was done in ANICE2.1 and it works)
      
      ! First, apply ICE5G GIA to high-resolution PD bedrock
      snapshot%Hb( vi) = PD%Hb( vi) + dHb_ICE5G( vi)
      
      ! Where ICE5G says there's ice, set the surface equal to the (smooth) GCM surface
      ! (this sort of solves the weird "block" structure of the ICE5G ice sheets)
      IF (mask_ice_ICE5G( vi) > 0.5_dp) THEN
        ! According to ICE5G, there's ice here.
        snapshot%Hs( vi) = MAX( snapshot%Hs_ref( vi), snapshot%Hb( vi))
        snapshot%Hi( vi) = MAX( 0._dp, snapshot%Hs( vi) - snapshot%Hb( vi))
      ELSE
        snapshot%Hs( vi) = MAX( snapshot%Hb( vi), snapshot%sealevel)
        snapshot%Hi( vi) = 0._dp
      END IF
      
    END DO
    
    ! Exception: remove unallowed ice
    DO vi = mesh%v1, mesh%v2
      IF (mask_noice( vi) == 1) THEN
        snapshot%Hs( vi) = MAX( snapshot%Hb( vi), snapshot%sealevel)
        snapshot%Hi( vi) = 0._dp
      END IF
    END DO
    
    ! Clean up after yourself
    CALL deallocate_shared( wHi_ICE5G)
    CALL deallocate_shared( wHb_ICE5G)
    CALL deallocate_shared( wHb_ICE5G_PD)
    CALL deallocate_shared( wmask_ice_ICE5G)
    CALL deallocate_shared( wdHb_ICE5G)
    
  END SUBROUTINE initialise_subclimate_ICE5G_geometry
  SUBROUTINE initialise_subclimate_spatially_variable_lapserate( mesh, grid_smooth, snapshot, snapshot_PI)
    ! Calculate the spatially variable lapse-rate (for non-PI GCM snapshots; see Berends et al., 2018)
    ! Only meaningful for snapshots where there is ice (LGM, M2_Medium, M2_Large),
    ! and only intended for North America and Eurasia
     
    IMPLICIT NONE
      
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh  
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    TYPE(type_subclimate_region),        INTENT(INOUT) :: snapshot
    TYPE(type_subclimate_region),        INTENT(IN)    :: snapshot_PI
    
    ! Local variables:
    INTEGER                                            :: vi,m
    REAL(dp)                                           :: dT_mean_nonice
    INTEGER                                            :: n_nonice, n_ice
    REAL(dp)                                           :: lambda_mean_ice
    
    REAL(dp), PARAMETER                                :: lambda_min = 0.002_dp
    REAL(dp), PARAMETER                                :: lambda_max = 0.05_dp
      
    ! Calculate the regional average temperature change outside of the ice sheet.
    ! ===========================================================================
    
    dT_mean_nonice = 0._dp
    n_nonice       = 0
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
      IF (snapshot%Hi( vi) <= 0.1_dp) THEN
        dT_mean_nonice = dT_mean_nonice + snapshot%T2m( vi,m) - snapshot_PI%T2m( vi,m)
        n_nonice = n_nonice + 1
      END IF
    END DO
    END DO
    
    CALL MPI_ALLREDUCE( MPI_IN_PLACE, dT_mean_nonice, 1, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, ierr)
    CALL MPI_ALLREDUCE( MPI_IN_PLACE, n_nonice,       1, MPI_INTEGER,          MPI_SUM, MPI_COMM_WORLD, ierr)
    
    dT_mean_nonice = dT_mean_nonice / REAL(n_nonice,dp)
    
    ! Calculate the lapse rate over the ice itself
    ! ============================================
    
    lambda_mean_ice = 0._dp
    n_ice           = 0
    
    DO vi = mesh%v1, mesh%v2
    
      snapshot%lambda( vi) = 0._dp
      
      IF (snapshot%Hi( vi) > 100._dp .AND. snapshot%Hs_ref( vi) > snapshot_PI%Hs_ref( vi)) THEN
      
        DO m = 1, 12
          snapshot%lambda( vi) = snapshot%lambda( vi) + 1/12._dp * MAX(lambda_min, MIN(lambda_max, &                        ! Berends et al., 2018 - Eq. 10
            -(snapshot%T2m( vi,m) - (snapshot_PI%T2m( vi,m) + dT_mean_nonice)) / (snapshot%Hs_ref( vi) - snapshot_PI%Hs_ref( vi))))
        END DO
        
        lambda_mean_ice = lambda_mean_ice + snapshot%lambda( vi)
        n_ice = n_ice + 1
        
      END IF
    
    END DO
    
    CALL MPI_ALLREDUCE( MPI_IN_PLACE, lambda_mean_ice, 1, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, ierr)
    CALL MPI_ALLREDUCE( MPI_IN_PLACE, n_ice,           1, MPI_INTEGER,          MPI_SUM, MPI_COMM_WORLD, ierr)
    
    lambda_mean_ice = lambda_mean_ice / n_ice
    
    ! Apply mean lapse-rate over ice to the rest of the region
    ! ========================================================
    
    DO vi = mesh%v1, mesh%v2
      IF (.NOT. (snapshot%Hi( vi) > 100._dp .AND. snapshot%Hs_ref( vi) > snapshot_PI%Hs_ref( vi))) THEN
        snapshot%lambda( vi) = lambda_mean_ice
      END IF
    END DO
    CALL sync
    
    ! Smooth the lapse rate field with a 160 km Gaussian filter
    CALL smooth_Gaussian_2D( mesh, grid_smooth, snapshot%lambda, 160000._dp)
    !CALL smooth_Shepard_2D( mesh, snapshot%lambda, 160000._dp)
    
    ! Normalise the entire region to a mean lapse rate of 8 K /km
    snapshot%lambda( mesh%v1:mesh%v2) = snapshot%lambda( mesh%v1:mesh%v2) * (0.008_dp / lambda_mean_ice)
    
  END SUBROUTINE initialise_subclimate_spatially_variable_lapserate
  SUBROUTINE initialise_subclimate_absorbed_insolation( mesh, snapshot, region_name, mask_noice, GCM_bias_T2m, GCM_bias_Precip)
    ! Calculate the yearly absorbed insolation for this (regional) GCM snapshot, to be used in the matrix interpolation
    
    USE netcdf_module, ONLY: read_insolation_data_file
    USE SMB_module,    ONLY: run_SMB_model
     
    IMPLICIT NONE
      
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh  
    TYPE(type_subclimate_region),        INTENT(INOUT) :: snapshot
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    INTEGER,  DIMENSION(:    ),          INTENT(IN)    :: mask_noice
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: GCM_bias_T2m
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: GCM_bias_Precip
    
    ! Local variables:
    INTEGER                                            :: vi,m,y
    REAL(dp), DIMENSION(:,:  ), POINTER                ::  Q_TOA0,  Q_TOA1
    INTEGER                                            :: wQ_TOA0, wQ_TOA1
    INTEGER                                            :: ti0, ti1
    REAL(dp)                                           :: ins_t0, ins_t1
    REAL(dp)                                           :: wt0, wt1
    INTEGER                                            :: ilat_l, ilat_u
    REAL(dp)                                           :: wlat_l, wlat_u
    
    REAL(dp), DIMENSION(:    ), POINTER                ::  dHs_dx_GCM,  dHs_dy_GCM,  dHs_dx_ISM,  dHs_dy_ISM
    INTEGER                                            :: wdHs_dx_GCM, wdHs_dy_GCM, wdHs_dx_ISM, wdHs_dy_ISM
    REAL(dp)                                           :: dT_lapse
    REAL(dp), DIMENSION(:,:  ), POINTER                ::  P_RL_GCM,  P_RL_ISM,  dP_RL
    INTEGER                                            :: wP_RL_GCM, wP_RL_ISM, wdP_RL
    
    TYPE(type_ice_model)                               :: ice_dummy
    TYPE(type_subclimate_region)                       :: climate_dummy
    TYPE(type_SMB_model)                               :: SMB_dummy
    
    ! Allocate shared memory
    CALL allocate_shared_dp_2D( forcing%ins_nlat, 12, Q_TOA0, wQ_TOA0)
    CALL allocate_shared_dp_2D( forcing%ins_nlat, 12, Q_TOA1, wQ_TOA1)
    
    ! Get insolation at the desired time from the insolation NetCDF file
    ! ==================================================================
    
    ins_t0 = 0
    ins_t1 = 0
    
    ! Find time indices to be read
    IF (snapshot%orbit_time >= MINVAL(forcing%ins_time) .AND. snapshot%orbit_time <= MAXVAL(forcing%ins_time)) THEN
      ti1 = 1
      DO WHILE (forcing%ins_time(ti1) < snapshot%orbit_time)
        ti1 = ti1 + 1
      END DO
      ti0 = ti1 - 1
      
      ins_t0 = forcing%ins_time(ti0)
      ins_t1 = forcing%ins_time(ti1)
    ELSE
      WRITE(0,*) '  ERROR - orbit_time ', snapshot%orbit_time, ' for snapshot ', TRIM(snapshot%name), ' outside of range of insolation solution file "', TRIM(forcing%netcdf_ins%filename), '"!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
    
    ! Read insolation time frames enveloping desired time from netcdf file
    IF (par%master) CALL read_insolation_data_file( forcing, ti0, ti1, Q_TOA0, Q_TOA1)
    CALL sync
    
    ! Map monthly insolation at the top of the atmosphere to the region grid
    ! Calculate time interpolation weights
    wt0 = (ins_t1 - snapshot%orbit_time) / (ins_t1 - ins_t0)
    wt1 = 1._dp - wt0
        
    ! Interpolate on the grid
    DO vi = mesh%v1, mesh%v2
     
      ilat_l = FLOOR(mesh%lat( vi) + 91)
      ilat_u = ilat_l + 1
      
      wlat_l = forcing%ins_lat( ilat_u) - mesh%lat( vi)
      wlat_u = 1._dp - wlat_l
      
      DO m = 1, 12
        snapshot%Q_TOA( vi,m) = (wt0 * wlat_l * Q_TOA0( ilat_l,m)) + &
                                (wt0 * wlat_u * Q_TOA0( ilat_u,m)) + &
                                (wt1 * wlat_l * Q_TOA1( ilat_l,m)) + &
                                (wt1 * wlat_u * Q_TOA1( ilat_u,m))
      END DO  
      
    END DO
    CALL sync
    
    ! Downscale the GCM snapshot from the (coarse) GCM geometry to the (fine) ISM geometry
    ! Store the downscaled climate in temporary memory.
    ! ====================================================================================
    
    ! Allocate temporary shared memory
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dx_GCM,     wdHs_dx_GCM    )
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dy_GCM,     wdHs_dy_GCM    )
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dx_ISM,     wdHs_dx_ISM    )
    CALL allocate_shared_dp_1D( mesh%nV    , dHs_dy_ISM,     wdHs_dy_ISM    )
    CALL allocate_shared_dp_2D( mesh%nV, 12, P_RL_GCM,       wP_RL_GCM      )
    CALL allocate_shared_dp_2D( mesh%nV, 12, P_RL_ISM,       wP_RL_ISM      )
    CALL allocate_shared_dp_2D( mesh%nV, 12, dP_RL,          wdP_RL         )
    
    CALL allocate_shared_int_1D(mesh%nV    , ice_dummy%mask_ocean   , ice_dummy%wmask_ocean   )
    CALL allocate_shared_int_1D(mesh%nV    , ice_dummy%mask_ice     , ice_dummy%wmask_ice     )
    CALL allocate_shared_int_1D(mesh%nV    , ice_dummy%mask_shelf   , ice_dummy%wmask_shelf   )
    
    ! Fill in masks for the SMB model
    DO vi = mesh%v1, mesh%v2
      
      IF (snapshot%Hb( vi) < snapshot%sealevel) THEN
        ice_dummy%mask_ocean( vi) = 1
      ELSE
        ice_dummy%mask_ocean( vi) = 0
      END IF
      
      IF (snapshot%Hi( vi) > 0._dp) THEN
        ice_dummy%mask_ice(   vi) = 1
      ELSE
        ice_dummy%mask_ice(   vi) = 0
      END IF
      
      IF (ice_dummy%mask_ocean( vi) == 1 .AND. ice_dummy%mask_ice( vi) == 1) THEN
        ice_dummy%mask_shelf( vi) = 1
      ELSE
        ice_dummy%mask_shelf( vi) = 0
      END IF
      
    END DO
    
    ! Surface slopes (needed by the RL precipitation model)
    CALL get_mesh_derivatives( mesh, snapshot%Hs_ref, dHs_dx_GCM, dHs_dy_GCM)
    CALL get_mesh_derivatives( mesh, snapshot%Hs,     dHs_dx_ISM, dHs_dy_ISM)
    
    ! Downscale temperature and precipitation from the GCM to the ISM geometry
    CALL allocate_shared_dp_2D( mesh%nV, 12, climate_dummy%T2m,    climate_dummy%wT2m)
    CALL allocate_shared_dp_2D( mesh%nV, 12, climate_dummy%Precip, climate_dummy%wPrecip)
    CALL allocate_shared_dp_2D( mesh%nV, 12, climate_dummy%Q_TOA,  climate_dummy%wQ_TOA)
    
    ! Temperature is downscaled with the GCM-derived variable lapse rate
    DO vi = mesh%v1, mesh%v2
      dT_lapse = snapshot%lambda( vi) * (snapshot%Hs( vi) - snapshot%Hs_ref( vi))
      climate_dummy%T2m( vi,:) = snapshot%T2m( vi,:) + dT_lapse
    END DO
      
    ! Precipication is downscaled with either the Roe&Lindzen model (for North America and Eurasia),
    ! or with the simpler inversion-layer-temperature-based correction (for Greenland and Antarctica).
    IF (region_name == 'NAM' .OR. region_name == 'EAS') THEN
    
      DO vi = mesh%v1, mesh%v2
      DO m = 1, 12
          
        ! RL precipitation for the GCM geometry
        CALL precipitation_model_Roe( snapshot%T2m( vi,m), dHs_dx_GCM( vi), dHs_dy_GCM( vi), snapshot%Wind_LR( vi,m), snapshot%Wind_DU( vi,m), P_RL_GCM( vi,m))
          
        ! RL precipitation for the ISM geometry
        CALL precipitation_model_Roe( climate_dummy%T2m( vi,m), dHs_dx_ISM( vi), dHs_dy_ISM( vi), snapshot%Wind_LR( vi,m), snapshot%Wind_DU( vi,m), P_RL_ISM( vi,m))
          
        ! Ratio between those two
        dP_RL( vi,m) = MIN( 2._dp, P_RL_ISM( vi,m) / P_RL_GCM( vi,m) )
          
        ! Applied model precipitation = (matrix-interpolated GCM reference precipitation) * RL ratio
        climate_dummy%Precip( vi,m) = snapshot%Precip( vi,m) * dP_RL( vi,m)
          
      END DO
      END DO
    
    ELSEIF (region_name == 'GRL' .OR. region_name == 'ANT') THEN
    
      CALL adapt_precip_CC(  mesh, snapshot%Hs, snapshot%Hs_ref, snapshot%T2m, snapshot%Precip, climate_dummy%Precip, region_name)
    
    END IF
        
    ! Correct for GCM bias (only for the PI snapshot, as the GCM data is still assumed to be The Truth (TM) for the LGM)
    IF (snapshot%name == 'HadCM3_PI') THEN
      climate_dummy%T2m(    mesh%v1:mesh%v2,:) = climate_dummy%T2m(    mesh%v1:mesh%v2,:) - GCM_bias_T2m(    mesh%v1:mesh%v2,:)
      climate_dummy%Precip( mesh%v1:mesh%v2,:) = climate_dummy%Precip( mesh%v1:mesh%v2,:) / GCM_bias_Precip( mesh%v1:mesh%v2,:)
    END IF
    
    ! Copy Q_TOA to the dummy climate
    climate_dummy%Q_TOA( mesh%v1:mesh%v2,:) = snapshot%Q_TOA( mesh%v1:mesh%v2,:)
    
    ! Create a temporary "dummy" ice & SMB data structure, so we can run the SMB model
    ! and determine the reference albedo field
    ! ================================================================================
    
    CALL allocate_shared_dp_1D( mesh%nV    , SMB_dummy%AlbedoSurf      , SMB_dummy%wAlbedoSurf      )
    CALL allocate_shared_dp_1D( mesh%nV    , SMB_dummy%MeltPreviousYear, SMB_dummy%wMeltPreviousYear)
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%FirnDepth       , SMB_dummy%wFirnDepth       )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%Rainfall        , SMB_dummy%wRainfall        )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%Snowfall        , SMB_dummy%wSnowfall        )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%AddedFirn       , SMB_dummy%wAddedFirn       )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%Melt            , SMB_dummy%wMelt            )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%Refreezing      , SMB_dummy%wRefreezing      )
    CALL allocate_shared_dp_1D( mesh%nV    , SMB_dummy%Refreezing_year , SMB_dummy%wRefreezing_year )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%Runoff          , SMB_dummy%wRunoff          )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%Albedo          , SMB_dummy%wAlbedo          )
    CALL allocate_shared_dp_1D( mesh%nV    , SMB_dummy%Albedo_year     , SMB_dummy%wAlbedo_year     )
    CALL allocate_shared_dp_2D( mesh%nV, 12, SMB_dummy%SMB             , SMB_dummy%wSMB             )
    CALL allocate_shared_dp_1D( mesh%nV    , SMB_dummy%SMB_year        , SMB_dummy%wSMB_year        )
    
    ! Tuning parameters
    CALL allocate_shared_dp_0D( SMB_dummy%C_abl_constant, SMB_dummy%wC_abl_constant)
    CALL allocate_shared_dp_0D( SMB_dummy%C_abl_Ts,       SMB_dummy%wC_abl_Ts      )
    CALL allocate_shared_dp_0D( SMB_dummy%C_abl_Q,        SMB_dummy%wC_abl_Q       )
    CALL allocate_shared_dp_0D( SMB_dummy%C_refr,         SMB_dummy%wC_refr        )
    
    IF (par%master) THEN
      IF     (region_name == 'NAM') THEN
        SMB_dummy%C_abl_constant = C%C_abl_constant_NAM
        SMB_dummy%C_abl_Ts       = C%C_abl_Ts_NAM
        SMB_dummy%C_abl_Q        = C%C_abl_Q_NAM
        SMB_dummy%C_refr         = C%C_refr_NAM
      ELSEIF (region_name == 'EAS') THEN
        SMB_dummy%C_abl_constant = C%C_abl_constant_EAS
        SMB_dummy%C_abl_Ts       = C%C_abl_Ts_EAS
        SMB_dummy%C_abl_Q        = C%C_abl_Q_EAS
        SMB_dummy%C_refr         = C%C_refr_EAS
      ELSEIF (region_name == 'GRL') THEN
        SMB_dummy%C_abl_constant = C%C_abl_constant_GRL
        SMB_dummy%C_abl_Ts       = C%C_abl_Ts_GRL
        SMB_dummy%C_abl_Q        = C%C_abl_Q_GRL
        SMB_dummy%C_refr         = C%C_refr_GRL
      ELSEIF (region_name == 'ANT') THEN
        SMB_dummy%C_abl_constant = C%C_abl_constant_ANT
        SMB_dummy%C_abl_Ts       = C%C_abl_Ts_ANT
        SMB_dummy%C_abl_Q        = C%C_abl_Q_ANT
        SMB_dummy%C_refr         = C%C_refr_ANT
      END IF
    END IF ! IF (par%master) THEN
    CALL sync
    
    ! Run the SMB model for 10 years for this particular snapshot
    ! (experimentally determined to be long enough to converge)
    DO y = 1, 10
      CALL run_SMB_model( mesh, ice_dummy, climate_dummy, 0._dp, SMB_dummy, mask_noice)
      !CALL run_SMB_model_refr_fixed( grid, ice_dummy, climate_dummy, 0._dp, SMB_dummy, mask_noice)
    END DO
    
    ! Copy the resulting albedo to the snapshot
    snapshot%Albedo( mesh%v1:mesh%v2,:) = SMB_dummy%Albedo( mesh%v1:mesh%v2,:)
    
    ! Calculate yearly total absorbed insolation
    snapshot%I_abs( mesh%v1:mesh%v2) = 0._dp
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
      snapshot%I_abs( vi) = snapshot%I_abs( vi) + snapshot%Q_TOA( vi,m) * (1._dp - snapshot%Albedo( vi,m))
    END DO
    END DO
    CALL sync
    
    ! Clean up after yourself
    CALL deallocate_shared( wQ_TOA0)
    CALL deallocate_shared( wQ_TOA1)
    CALL deallocate_shared( wdHs_dx_GCM)
    CALL deallocate_shared( wdHs_dy_GCM)
    CALL deallocate_shared( wdHs_dx_ISM)
    CALL deallocate_shared( wdHs_dy_ISM)
    CALL deallocate_shared( wP_RL_GCM)
    CALL deallocate_shared( wP_RL_ISM)
    CALL deallocate_shared( wdP_RL)
    CALL deallocate_shared( ice_dummy%wmask_ocean)
    CALL deallocate_shared( ice_dummy%wmask_ice)
    CALL deallocate_shared( ice_dummy%wmask_shelf)
    CALL deallocate_shared( climate_dummy%wT2m)
    CALL deallocate_shared( climate_dummy%wPrecip)
    CALL deallocate_shared( climate_dummy%wQ_TOA)
    CALL deallocate_shared( SMB_dummy%wAlbedoSurf)
    CALL deallocate_shared( SMB_dummy%wMeltPreviousYear)
    CALL deallocate_shared( SMB_dummy%wFirnDepth)
    CALL deallocate_shared( SMB_dummy%wRainfall)
    CALL deallocate_shared( SMB_dummy%wSnowfall)
    CALL deallocate_shared( SMB_dummy%wAddedFirn)
    CALL deallocate_shared( SMB_dummy%wMelt)
    CALL deallocate_shared( SMB_dummy%wRefreezing)
    CALL deallocate_shared( SMB_dummy%wRefreezing_year)
    CALL deallocate_shared( SMB_dummy%wRunoff)
    CALL deallocate_shared( SMB_dummy%wAlbedo)
    CALL deallocate_shared( SMB_dummy%wAlbedo_year)
    CALL deallocate_shared( SMB_dummy%wSMB)
    CALL deallocate_shared( SMB_dummy%wSMB_year)
    CALL deallocate_shared( SMB_dummy%wC_abl_constant)
    CALL deallocate_shared( SMB_dummy%wC_abl_Ts)
    CALL deallocate_shared( SMB_dummy%wC_abl_Q)
    CALL deallocate_shared( SMB_dummy%wC_refr)
    
  END SUBROUTINE initialise_subclimate_absorbed_insolation
  
  ! Map a global subclimate from the matrix (PD observed or GCM snapshot) to a region mesh
  SUBROUTINE map_subclimate_to_mesh( mesh,  cglob, creg)
    ! Map data from a global "subclimate" (PD observed or cglobM snapshot) to the mesh
    
    IMPLICIT NONE
    
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh 
    TYPE(type_subclimate_global),        INTENT(IN)    :: cglob    ! Global climate
    TYPE(type_subclimate_region),        INTENT(INOUT) :: creg     ! Mesh   climate
    
    ! Local variables:
    TYPE(type_remapping_latlon2mesh)                   :: map
    
    ! If this snapshot is not used, don't do anything
    IF (creg%name == 'none') RETURN
    
    IF (par%master) WRITE(0,*) '   Mapping ', TRIM(cglob%name), ' data from global grid to mesh...'
    
    ! Calculate mapping arrays
    CALL create_remapping_arrays_glob_mesh( mesh, cglob%grid, map)
    
    ! Map global climate data to the mesh
    CALL map_latlon2mesh_3D( mesh, map, cglob%T2m,     creg%T2m    )
    CALL map_latlon2mesh_3D( mesh, map, cglob%Precip,  creg%Precip )
    CALL map_latlon2mesh_2D( mesh, map, cglob%Hs_ref,  creg%Hs_ref )
    CALL map_latlon2mesh_3D( mesh, map, cglob%Wind_WE, creg%Wind_WE)
    CALL map_latlon2mesh_3D( mesh, map, cglob%Wind_SN, creg%Wind_SN)
    
    ! Deallocate mapping arrays
    CALL deallocate_remapping_arrays_glob_mesh( map)
    
    ! Rotate zonal/meridional wind to x,y wind
    CALL rotate_wind_to_model_mesh( mesh, creg%wind_WE, creg%wind_SN, creg%wind_LR, creg%wind_DU)
  
  END SUBROUTINE map_subclimate_to_mesh

  ! Initialising the climate matrix, containing all the global subclimates
  ! (PD observations and GCM snapshots)
  SUBROUTINE initialise_climate_matrix( matrix)
    ! Allocate shared memory for the global climate matrix
  
    IMPLICIT NONE
    
    ! In/output variables:
    TYPE(type_climate_matrix),      INTENT(INOUT) :: matrix
    
    ! Local variables
    CHARACTER(LEN=64), PARAMETER                  :: routine_name = 'initialise_climate_matrix'
    INTEGER                                       :: n1, n2
    
    n1 = par%mem%n
    
    IF (C%do_benchmark_experiment) THEN
      IF (C%choice_benchmark_experiment == 'EISMINT_1' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_2' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_3' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_4' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_5' .OR. &
          C%choice_benchmark_experiment == 'EISMINT_6' .OR. &
          C%choice_benchmark_experiment == 'Halfar' .OR. &
          C%choice_benchmark_experiment == 'Bueler' .OR. &
          C%choice_benchmark_experiment == 'MISMIP_mod'.OR. &
          C%choice_benchmark_experiment == 'mesh_generation_test') THEN
        ! Entirely parameterised climate, no need to read anything here
        RETURN
      ELSE
        WRITE(0,*) '  ERROR: benchmark experiment "', TRIM(C%choice_benchmark_experiment), '" not implemented in initialise_PD_obs_data_fields!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
    END IF
    
    IF (par%master) WRITE(0,*) ''
    IF (par%master) WRITE(0,*) ' Initialising the climate matrix...'
    
    ! The global ERA40 climate
    CALL initialise_PD_obs_data_fields( matrix%PD_obs, 'ERA40')
    
    ! The differenct GCM snapshots 
    IF (C%choice_forcing_method == 'd18O_inverse_dT_glob') THEN
      ! This choice of forcing doesn't use any GCM data
      RETURN
    ELSEIF (C%choice_forcing_method == 'CO2_direct' .OR. C%choice_forcing_method == 'd18O_inverse_CO2') THEN
      ! These two choices use the climate matrix
      
      IF (C%choice_climate_matrix == 'PI_LGM') THEN
      
        ! Initialise the GCM snapshots
        CALL initialise_snapshot( matrix%GCM_PI,  name = 'HadCM3_PI',  nc_filename = C%filename_GCM_snapshot_PI,  CO2 = 280._dp, orbit_time =       0._dp)
        CALL initialise_snapshot( matrix%GCM_LGM, name = 'HadCM3_LGM', nc_filename = C%filename_GCM_snapshot_LGM, CO2 = 190._dp, orbit_time = -120000._dp)
        
        ! Initialise the two ICE5G timeframes
        CALL initialise_ICE5G_timeframe( matrix%ICE5G_PD,  nc_filename = C%filename_ICE5G_PD,  time =       0._dp)
        CALL initialise_ICE5G_timeframe( matrix%ICE5G_LGM, nc_filename = C%filename_ICE5G_LGM, time = -120000._dp)
    
        ! ICE5G defines bedrock w.r.t. sea level at that time, rather than sea level at PD. Correct for this.
        IF (par%master) matrix%ICE5G_LGM%Hb = matrix%ICE5G_LGM%Hb - 119._dp
        CALL sync
        
      ELSE
        IF (par%master) WRITE(0,*) '  ERROR: choice_climate_matrix "', TRIM(C%choice_climate_matrix), '" not implemented in initialise_climate_matrix!'
        CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
      END IF
      
    ELSE
      IF (par%master) WRITE(0,*) '  ERROR: choice_forcing_method "', TRIM(C%choice_forcing_method), '" not implemented in initialise_climate_matrix!'
      CALL MPI_ABORT( MPI_COMM_WORLD, cerr, ierr)
    END IF
    
    n2 = par%mem%n
    CALL write_to_memory_log( routine_name, n1, n2)
    
  END SUBROUTINE initialise_climate_matrix  
  SUBROUTINE initialise_PD_obs_data_fields( PD_obs, name)
    ! Allocate shared memory for the global PD observed climate data fields (stored in the climate matrix),
    ! read them from the specified NetCDF file (latter only done by master process).
     
    IMPLICIT NONE
      
    ! Input variables:
    TYPE(type_subclimate_global),   INTENT(INOUT) :: PD_obs
    CHARACTER(LEN=*),               INTENT(IN)    :: name
    
    PD_obs%name = name 
    PD_obs%netcdf%filename   = C%filename_PD_obs_climate 
    
    ! General forcing info (not relevant for PD_obs, but needed so that the same mapping routines as for GCM snapshots can be used)
    CALL allocate_shared_dp_0D(                PD_obs%CO2,        PD_obs%wCO2       )
    CALL allocate_shared_dp_0D(                PD_obs%orbit_time, PD_obs%worbit_time)
    CALL allocate_shared_dp_0D(                PD_obs%orbit_ecc,  PD_obs%worbit_ecc )
    CALL allocate_shared_dp_0D(                PD_obs%orbit_obl,  PD_obs%worbit_obl )
    CALL allocate_shared_dp_0D(                PD_obs%orbit_pre,  PD_obs%worbit_pre )
        
    ! Inquire if all required variables are present in the NetCDF file, and read the grid size.
    CALL allocate_shared_int_0D(       PD_obs%grid%nlon, PD_obs%grid%wnlon     )
    CALL allocate_shared_int_0D(       PD_obs%grid%nlat, PD_obs%grid%wnlat     )
    IF (par%master) CALL inquire_PD_obs_data_file( PD_obs)
    CALL sync
    
    ! Allocate memory  
    CALL allocate_shared_dp_1D( PD_obs%grid%nlon,                       PD_obs%grid%lon, PD_obs%grid%wlon)
    CALL allocate_shared_dp_1D(                   PD_obs%grid%nlat,     PD_obs%grid%lat, PD_obs%grid%wlat)
    CALL allocate_shared_dp_2D( PD_obs%grid%nlon, PD_obs%grid%nlat,     PD_obs%Hs_ref,   PD_obs%wHs_ref  )
    CALL allocate_shared_dp_3D( PD_obs%grid%nlon, PD_obs%grid%nlat, 12, PD_obs%T2m,      PD_obs%wT2m     )
    CALL allocate_shared_dp_3D( PD_obs%grid%nlon, PD_obs%grid%nlat, 12, PD_obs%Precip,   PD_obs%wPrecip  )
    CALL allocate_shared_dp_3D( PD_obs%grid%nlon, PD_obs%grid%nlat, 12, PD_obs%Wind_WE,  PD_obs%wWind_WE )
    CALL allocate_shared_dp_3D( PD_obs%grid%nlon, PD_obs%grid%nlat, 12, PD_obs%Wind_SN,  PD_obs%wWind_SN )
    
    ! Read data from the NetCDF file
    IF (par%master) WRITE(0,*) '   Reading PD observed climate data from file ', TRIM(PD_obs%netcdf%filename), '...'
    IF (par%master) CALL read_PD_obs_data_file( PD_obs)
    CALL sync
      
    ! Determine process domains
    CALL partition_list( PD_obs%grid%nlon, par%i, par%n, PD_obs%grid%i1, PD_obs%grid%i2)
    
  END SUBROUTINE initialise_PD_obs_data_fields  
  SUBROUTINE initialise_snapshot( snapshot, name, nc_filename, CO2, orbit_time)
    ! Allocate shared memory for the data fields of a GCM snapshot (stored in the climate matrix),
    ! read them from the specified NetCDF file (latter only done by master process).
     
    IMPLICIT NONE
      
    ! In/output variables:
    TYPE(type_subclimate_global),   INTENT(INOUT) :: snapshot
    CHARACTER(LEN=*),               INTENT(IN)    :: name
    CHARACTER(LEN=*),               INTENT(IN)    :: nc_filename
    REAL(dp),                       INTENT(IN)    :: CO2
    REAL(dp),                       INTENT(IN)    :: orbit_time
    
    ! Local variables:
    INTEGER                                       :: i,j,m
    REAL(dp), PARAMETER                           :: Precip_minval = 1E-5_dp
    
    ! Metadata
    snapshot%name            = name 
    snapshot%netcdf%filename = nc_filename
    
    ! General forcing info
    CALL allocate_shared_dp_0D( snapshot%CO2,        snapshot%wCO2       )
    CALL allocate_shared_dp_0D( snapshot%orbit_time, snapshot%worbit_time)
    CALL allocate_shared_dp_0D( snapshot%orbit_ecc,  snapshot%worbit_ecc )
    CALL allocate_shared_dp_0D( snapshot%orbit_obl,  snapshot%worbit_obl )
    CALL allocate_shared_dp_0D( snapshot%orbit_pre,  snapshot%worbit_pre )
    
    snapshot%CO2        = CO2
    snapshot%orbit_time = orbit_time
    
    ! Inquire if all required variables are present in the NetCDF file, and read the grid size.
    CALL allocate_shared_int_0D( snapshot%grid%nlon, snapshot%grid%wnlon)
    CALL allocate_shared_int_0D( snapshot%grid%nlat, snapshot%grid%wnlat)
    IF (par%master) CALL inquire_GCM_snapshot( snapshot)
    CALL sync
    
    ! Allocate memory  
    CALL allocate_shared_dp_1D( snapshot%grid%nlon,                         snapshot%grid%lon, snapshot%grid%wlon)
    CALL allocate_shared_dp_1D(                     snapshot%grid%nlat,     snapshot%grid%lat, snapshot%grid%wlat)
    CALL allocate_shared_dp_2D( snapshot%grid%nlon, snapshot%grid%nlat,     snapshot%Hs_ref,   snapshot%wHs_ref  )
    CALL allocate_shared_dp_3D( snapshot%grid%nlon, snapshot%grid%nlat, 12, snapshot%T2m,      snapshot%wT2m     )
    CALL allocate_shared_dp_3D( snapshot%grid%nlon, snapshot%grid%nlat, 12, snapshot%Precip,   snapshot%wPrecip  )
    CALL allocate_shared_dp_3D( snapshot%grid%nlon, snapshot%grid%nlat, 12, snapshot%Wind_WE,  snapshot%wWind_WE )
    CALL allocate_shared_dp_3D( snapshot%grid%nlon, snapshot%grid%nlat, 12, snapshot%Wind_SN,  snapshot%wWind_SN )
    
    ! Read data from the NetCDF file
    IF (par%master) WRITE(0,*) '   Reading GCM snapshot ', TRIM(snapshot%name), ' from file ', TRIM(snapshot%netcdf%filename), '...'
    IF (par%master) CALL read_GCM_snapshot( snapshot)
    CALL sync
      
    ! Determine process domains
    CALL partition_list( snapshot%grid%nlon, par%i, par%n, snapshot%grid%i1, snapshot%grid%i2)
    
    ! Very rarely zero precipitation can occur in GCM snapshots, which gives problems with the matrix interpolation. Fix this.
    DO i = snapshot%grid%i1, snapshot%grid%i2
    DO j = 1, snapshot%grid%nlat
    DO m = 1, 12
      snapshot%Precip( i,j,m) = MAX( Precip_minval, snapshot%Precip( i,j,m))
    END DO
    END DO
    END DO
    CALL sync
    
  END SUBROUTINE initialise_snapshot
  SUBROUTINE initialise_ICE5G_timeframe( ICE5G, nc_filename, time)
    ! Initialise and read a global ICE5G timeframe from a NetCDF file
     
    IMPLICIT NONE
      
    ! In/output variables:
    TYPE(type_ICE5G_timeframe),     INTENT(INOUT) :: ICE5G
    CHARACTER(LEN=*),               INTENT(IN)    :: nc_filename
    REAL(dp),                       INTENT(IN)    :: time
    
    ICE5G%time            = time
    ICE5G%netcdf%filename = nc_filename
    
    ! Inquire if all required variables are present in the NetCDF file, and read the grid size.
    CALL allocate_shared_int_0D( ICE5G%grid%nlon, ICE5G%grid%wnlon)
    CALL allocate_shared_int_0D( ICE5G%grid%nlat, ICE5G%grid%wnlat)
    IF (par%master) CALL inquire_ICE5G_data( ICE5G)
    CALL sync
    
    ! Allocate memory  
    CALL allocate_shared_dp_1D( ICE5G%grid%nlon,                  ICE5G%grid%lon, ICE5G%grid%wlon)
    CALL allocate_shared_dp_1D(                  ICE5G%grid%nlat, ICE5G%grid%lat, ICE5G%grid%wlat)
    CALL allocate_shared_dp_2D( ICE5G%grid%nlon, ICE5G%grid%nlat, ICE5G%Hi,       ICE5G%wHi      )
    CALL allocate_shared_dp_2D( ICE5G%grid%nlon, ICE5G%grid%nlat, ICE5G%Hb,       ICE5G%wHb      )
    CALL allocate_shared_dp_2D( ICE5G%grid%nlon, ICE5G%grid%nlat, ICE5G%mask_ice, ICE5G%wmask_ice)
    
    ! Read data from the NetCDF file
    IF (par%master) WRITE(0,'(A,F9.1,A,A,A)') '    Reading ICE5G timeframe for t = ', time, ' yr from file ', TRIM(ICE5G%netcdf%filename), '...'
    IF (par%master) CALL read_ICE5G_data( ICE5G)
    CALL sync
      
    ! Determine process domains
    CALL partition_list( ICE5G%grid%nlon, par%i, par%n, ICE5G%grid%i1, ICE5G%grid%i2)
    
  END SUBROUTINE initialise_ICE5G_timeframe
  
  ! Remap the regional climate model after a mesh update
  SUBROUTINE remap_climate_model( mesh_old, mesh_new, map, climate, matrix, PD, grid_smooth, mask_noice, region_name)
    ! Reallocate all the data fields (no remapping needed, instead we just run
    ! the climate model immediately after a mesh update)
     
    IMPLICIT NONE
  
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(INOUT) :: mesh_old
    TYPE(type_mesh),                     INTENT(INOUT) :: mesh_new
    TYPE(type_remapping),                INTENT(IN)    :: map
    TYPE(type_climate_model),            INTENT(INOUT) :: climate
    TYPE(type_climate_matrix),           INTENT(IN)    :: matrix
    TYPE(type_PD_data_fields),           INTENT(IN)    :: PD
    TYPE(type_grid),                     INTENT(IN)    :: grid_smooth
    INTEGER,  DIMENSION(:    ),          INTENT(IN)    :: mask_noice
    CHARACTER(LEN=3),                    INTENT(IN)    :: region_name
    
    ! Local variables:
    INTEGER                                            :: int_dummy
    
    int_dummy = map%conservative%n_tot
    int_dummy = mesh_old%nV

    ! Reallocate memory for the different subclimates
    CALL reallocate_subclimate( mesh_new, climate%applied)
     
    IF (.NOT. climate%PD_obs%name == 'none') THEN
      CALL reallocate_subclimate(  mesh_new, climate%PD_obs)
      CALL map_subclimate_to_mesh( mesh_new, matrix%PD_obs,  climate%PD_obs )
    END IF
     
    IF (.NOT. climate%GCM_PI%name == 'none') THEN
      ! Reallocate and reinitialise the two GCM snapshots
    
      ! Reallocate memory
      CALL reallocate_subclimate(  mesh_new, climate%GCM_PI)
      CALL reallocate_subclimate(  mesh_new, climate%GCM_LGM)
      
      ! Map GCM data from the global lat-lon grid to the model mesh
      CALL map_subclimate_to_mesh( mesh_new, matrix%GCM_PI,  climate%GCM_PI )
      CALL map_subclimate_to_mesh( mesh_new, matrix%GCM_LGM, climate%GCM_LGM)
        
      ! Right now, no wind is read from GCM output; just use PD observations everywhere
      climate%GCM_PI%Wind_WE(  mesh_new%v1:mesh_new%v2,:) = climate%PD_obs%Wind_WE( mesh_new%v1:mesh_new%v2,:)
      climate%GCM_PI%Wind_SN(  mesh_new%v1:mesh_new%v2,:) = climate%PD_obs%Wind_SN( mesh_new%v1:mesh_new%v2,:)
      climate%GCM_LGM%Wind_WE( mesh_new%v1:mesh_new%v2,:) = climate%PD_obs%Wind_WE( mesh_new%v1:mesh_new%v2,:)
      climate%GCM_LGM%Wind_SN( mesh_new%v1:mesh_new%v2,:) = climate%PD_obs%Wind_SN( mesh_new%v1:mesh_new%v2,:)
      
      ! Initialise ICE5G geometry
      CALL initialise_subclimate_ICE5G_geometry( mesh_new, climate%GCM_PI,  PD, matrix%ICE5G_PD,  matrix%ICE5G_PD, mask_noice)
      CALL initialise_subclimate_ICE5G_geometry( mesh_new, climate%GCM_LGM, PD, matrix%ICE5G_LGM, matrix%ICE5G_PD, mask_noice)
      
      ! Calculate spatially variable lapse rate
      climate%GCM_PI%lambda = 0.008_dp
      IF     (region_name == 'NAM' .OR. region_name == 'EAS') THEN
        CALL initialise_subclimate_spatially_variable_lapserate( mesh_new, grid_smooth, climate%GCM_LGM, climate%GCM_PI)
      ELSEIF (region_name == 'GLR' .OR. region_name == 'ANT') THEN
        climate%GCM_LGM%lambda = 0.008_dp
      END IF
  
      ! Calculate GCM climate bias
      CALL deallocate_shared( climate%wGCM_bias_T2m   )
      CALL deallocate_shared( climate%wGCM_bias_Precip)
      CALL initialise_climate_model_GCM_bias( mesh_new, climate)
      
      ! Get reference absorbed insolation for the GCM snapshots
      CALL initialise_subclimate_absorbed_insolation( mesh_new, climate%GCM_PI , region_name, mask_noice, climate%GCM_bias_T2m, climate%GCM_bias_Precip)
      CALL initialise_subclimate_absorbed_insolation( mesh_new, climate%GCM_LGM, region_name, mask_noice, climate%GCM_bias_T2m, climate%GCM_bias_Precip)
      
    END IF ! IF (.NOT. climate%GCM_PI%name == 'none') THEN
    
  END SUBROUTINE remap_climate_model
  SUBROUTINE reallocate_subclimate( mesh_new, subclimate)
    ! Reallocate data fields of a regional subclimate after a mesh update
     
    IMPLICIT NONE
  
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh_new
    TYPE(type_subclimate_region),        INTENT(INOUT) :: subclimate
    
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%T2m,        subclimate%wT2m      , 12)
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Precip,     subclimate%wPrecip   , 12)
    CALL reallocate_field_dp(    mesh_new%nV,  subclimate%Hs_ref,     subclimate%wHs_ref       )
    CALL reallocate_field_dp(    mesh_new%nV,  subclimate%Hi,         subclimate%wHi           )
    CALL reallocate_field_dp(    mesh_new%nV,  subclimate%Hb,         subclimate%wHb           )
    CALL reallocate_field_dp(    mesh_new%nV,  subclimate%Hs,         subclimate%wHs           )
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Wind_WE,    subclimate%wWind_WE  , 12)
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Wind_SN,    subclimate%wWind_SN  , 12)
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Wind_LR,    subclimate%wWind_LR  , 12)
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Wind_DU,    subclimate%wWind_DU  , 12)
    
    CALL reallocate_field_dp(    mesh_new%nV,  subclimate%lambda,     subclimate%wlambda       )
    
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Q_TOA,      subclimate%wQ_TOA    , 12)
    CALL reallocate_field_dp_3D( mesh_new%nV,  subclimate%Albedo,     subclimate%wAlbedo   , 12)
    CALL reallocate_field_dp(    mesh_new%nV,  subclimate%I_abs,      subclimate%wI_abs        )
    
  END SUBROUTINE reallocate_subclimate
  
  ! Rotate wind_WE, wind_SN to wind_LR, wind_DU
  SUBROUTINE rotate_wind_to_model_mesh( mesh, wind_WE, wind_SN, wind_LR, wind_DU)
    ! Code copied from ANICE.
    
    USE parameters_module, ONLY: pi
    
    IMPLICIT NONE
    
    ! In/output variables:
    TYPE(type_mesh),                     INTENT(IN)    :: mesh
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: wind_WE
    REAL(dp), DIMENSION(:,:  ),          INTENT(IN)    :: wind_SN
    REAL(dp), DIMENSION(:,:  ),          INTENT(OUT)   :: wind_LR
    REAL(dp), DIMENSION(:,:  ),          INTENT(OUT)   :: wind_DU
    
    ! Local variables:
    INTEGER                                            :: vi,m
    REAL(dp)                                           :: longitude_start, Uwind_x, Uwind_y, Vwind_x, Vwind_y

    ! First find the first longitude which defines the start of quadrant I:
    longitude_start = mesh%lambda_M - 90._dp
    
    DO vi = mesh%v1, mesh%v2
    DO m = 1, 12
      
      ! calculate x and y from the zonal wind
      Uwind_x =   wind_WE( vi,m) * SIN((pi/180._dp) * (mesh%lon( vi) - longitude_start))
      Uwind_y = - wind_WE( vi,m) * COS((pi/180._dp) * (mesh%lon( vi) - longitude_start))
  
      ! calculate x and y from the meridional winds
      Vwind_x =   wind_SN( vi,m) * COS((pi/180._dp) * (mesh%lon( vi) - longitude_start))
      Vwind_y =   wind_SN( vi,m) * SIN((pi/180._dp) * (mesh%lon( vi) - longitude_start))
  
      ! Sum up wind components
      wind_LR( vi,m) = Uwind_x + Vwind_x   ! winds left to right
      wind_DU( vi,m) = Uwind_y + Vwind_y   ! winds bottom to top
      
    END DO
    END DO
    CALL sync
    
  END SUBROUTINE rotate_wind_to_model_mesh

END MODULE climate_module
