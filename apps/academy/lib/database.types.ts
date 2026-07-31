export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      academic_clone_run: {
        Row: {
          campus_id: string
          from_session_id: string
          id: string
          is_dry_run: boolean
          run_at: string
          run_by: string | null
          summary: Json
          tenant_id: string
          to_session_id: string
        }
        Insert: {
          campus_id: string
          from_session_id: string
          id?: string
          is_dry_run: boolean
          run_at?: string
          run_by?: string | null
          summary: Json
          tenant_id: string
          to_session_id: string
        }
        Update: {
          campus_id?: string
          from_session_id?: string
          id?: string
          is_dry_run?: boolean
          run_at?: string
          run_by?: string | null
          summary?: Json
          tenant_id?: string
          to_session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "academic_clone_run_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "academic_clone_run_from_session_id_fkey"
            columns: ["from_session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "academic_clone_run_run_by_fkey"
            columns: ["run_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "academic_clone_run_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "academic_clone_run_to_session_id_fkey"
            columns: ["to_session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
        ]
      }
      academic_session: {
        Row: {
          admission_opens_on: string | null
          campus_id: string | null
          created_at: string
          ends_on: string
          id: string
          is_current: boolean
          name: string
          result_locked_at: string | null
          starts_on: string
          status: Database["public"]["Enums"]["session_status"]
          tenant_id: string
        }
        Insert: {
          admission_opens_on?: string | null
          campus_id?: string | null
          created_at?: string
          ends_on: string
          id?: string
          is_current?: boolean
          name: string
          result_locked_at?: string | null
          starts_on: string
          status?: Database["public"]["Enums"]["session_status"]
          tenant_id: string
        }
        Update: {
          admission_opens_on?: string | null
          campus_id?: string | null
          created_at?: string
          ends_on?: string
          id?: string
          is_current?: boolean
          name?: string
          result_locked_at?: string | null
          starts_on?: string
          status?: Database["public"]["Enums"]["session_status"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "academic_session_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "academic_session_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      academic_term: {
        Row: {
          created_at: string
          ends_on: string
          id: string
          is_locked: boolean
          name: string
          name_ur: string | null
          sequence: number
          session_id: string
          starts_on: string
          tenant_id: string
          weightage: number
        }
        Insert: {
          created_at?: string
          ends_on: string
          id?: string
          is_locked?: boolean
          name: string
          name_ur?: string | null
          sequence: number
          session_id: string
          starts_on: string
          tenant_id: string
          weightage: number
        }
        Update: {
          created_at?: string
          ends_on?: string
          id?: string
          is_locked?: boolean
          name?: string
          name_ur?: string | null
          sequence?: number
          session_id?: string
          starts_on?: string
          tenant_id?: string
          weightage?: number
        }
        Relationships: [
          {
            foreignKeyName: "academic_term_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "academic_term_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      admission_application: {
        Row: {
          application_no: string | null
          campus_id: string
          class_applied_id: string
          created_at: string
          enquiry_id: string
          group_applied: Database["public"]["Enums"]["academic_group"] | null
          id: string
          prev_class_passed: string | null
          prev_school: string | null
          session_id: string
          status: Database["public"]["Enums"]["application_status"]
          submitted_at: string
          submitted_by: string | null
          tenant_id: string
        }
        Insert: {
          application_no?: string | null
          campus_id: string
          class_applied_id: string
          created_at?: string
          enquiry_id: string
          group_applied?: Database["public"]["Enums"]["academic_group"] | null
          id?: string
          prev_class_passed?: string | null
          prev_school?: string | null
          session_id: string
          status?: Database["public"]["Enums"]["application_status"]
          submitted_at?: string
          submitted_by?: string | null
          tenant_id: string
        }
        Update: {
          application_no?: string | null
          campus_id?: string
          class_applied_id?: string
          created_at?: string
          enquiry_id?: string
          group_applied?: Database["public"]["Enums"]["academic_group"] | null
          id?: string
          prev_class_passed?: string | null
          prev_school?: string | null
          session_id?: string
          status?: Database["public"]["Enums"]["application_status"]
          submitted_at?: string
          submitted_by?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "admission_application_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_application_class_applied_id_fkey"
            columns: ["class_applied_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_application_enquiry_id_fkey"
            columns: ["enquiry_id"]
            isOneToOne: false
            referencedRelation: "admission_enquiry"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_application_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_application_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_application_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      admission_enquiry: {
        Row: {
          age_override_reason: string | null
          assigned_to: string | null
          campus_id: string
          child_name: string
          child_name_ur: string | null
          class_applied_id: string
          created_at: string
          dob: string
          enquiry_no: string | null
          id: string
          merged_into_id: string | null
          parent_cnic: string | null
          parent_name: string
          phone_e164: string
          referrer_name: string | null
          referrer_student_id: string | null
          session_id: string
          source: Database["public"]["Enums"]["enquiry_source"]
          status: Database["public"]["Enums"]["enquiry_status"]
          tenant_id: string
          whatsapp_opt_in: boolean
        }
        Insert: {
          age_override_reason?: string | null
          assigned_to?: string | null
          campus_id: string
          child_name: string
          child_name_ur?: string | null
          class_applied_id: string
          created_at?: string
          dob: string
          enquiry_no?: string | null
          id?: string
          merged_into_id?: string | null
          parent_cnic?: string | null
          parent_name: string
          phone_e164: string
          referrer_name?: string | null
          referrer_student_id?: string | null
          session_id: string
          source: Database["public"]["Enums"]["enquiry_source"]
          status?: Database["public"]["Enums"]["enquiry_status"]
          tenant_id: string
          whatsapp_opt_in?: boolean
        }
        Update: {
          age_override_reason?: string | null
          assigned_to?: string | null
          campus_id?: string
          child_name?: string
          child_name_ur?: string | null
          class_applied_id?: string
          created_at?: string
          dob?: string
          enquiry_no?: string | null
          id?: string
          merged_into_id?: string | null
          parent_cnic?: string | null
          parent_name?: string
          phone_e164?: string
          referrer_name?: string | null
          referrer_student_id?: string | null
          session_id?: string
          source?: Database["public"]["Enums"]["enquiry_source"]
          status?: Database["public"]["Enums"]["enquiry_status"]
          tenant_id?: string
          whatsapp_opt_in?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "admission_enquiry_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_enquiry_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_enquiry_class_applied_id_fkey"
            columns: ["class_applied_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_enquiry_merged_into_id_fkey"
            columns: ["merged_into_id"]
            isOneToOne: false
            referencedRelation: "admission_enquiry"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_enquiry_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_enquiry_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      admission_followup: {
        Row: {
          assigned_to: string | null
          campus_id: string
          channel: Database["public"]["Enums"]["followup_channel"]
          completed_at: string | null
          completed_by: string | null
          created_at: string
          created_by: string | null
          due_at: string
          enquiry_id: string
          id: string
          outcome: Database["public"]["Enums"]["followup_outcome"] | null
          outcome_note: string | null
          tenant_id: string
        }
        Insert: {
          assigned_to?: string | null
          campus_id: string
          channel: Database["public"]["Enums"]["followup_channel"]
          completed_at?: string | null
          completed_by?: string | null
          created_at?: string
          created_by?: string | null
          due_at: string
          enquiry_id: string
          id?: string
          outcome?: Database["public"]["Enums"]["followup_outcome"] | null
          outcome_note?: string | null
          tenant_id: string
        }
        Update: {
          assigned_to?: string | null
          campus_id?: string
          channel?: Database["public"]["Enums"]["followup_channel"]
          completed_at?: string | null
          completed_by?: string | null
          created_at?: string
          created_by?: string | null
          due_at?: string
          enquiry_id?: string
          id?: string
          outcome?: Database["public"]["Enums"]["followup_outcome"] | null
          outcome_note?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "admission_followup_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_followup_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_followup_completed_by_fkey"
            columns: ["completed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_followup_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_followup_enquiry_id_fkey"
            columns: ["enquiry_id"]
            isOneToOne: false
            referencedRelation: "admission_enquiry"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_followup_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      admission_offer: {
        Row: {
          admission_fee_amount: number
          application_id: string
          class_level_id: string
          created_at: string
          decline_reason:
            | Database["public"]["Enums"]["offer_decline_reason"]
            | null
          expires_at: string
          extended_by: string | null
          extension_reason: string | null
          id: string
          issued_at: string
          issued_by: string | null
          responded_at: string | null
          section_id: string | null
          status: Database["public"]["Enums"]["offer_status"]
          tenant_id: string
        }
        Insert: {
          admission_fee_amount: number
          application_id: string
          class_level_id: string
          created_at?: string
          decline_reason?:
            | Database["public"]["Enums"]["offer_decline_reason"]
            | null
          expires_at: string
          extended_by?: string | null
          extension_reason?: string | null
          id?: string
          issued_at?: string
          issued_by?: string | null
          responded_at?: string | null
          section_id?: string | null
          status?: Database["public"]["Enums"]["offer_status"]
          tenant_id: string
        }
        Update: {
          admission_fee_amount?: number
          application_id?: string
          class_level_id?: string
          created_at?: string
          decline_reason?:
            | Database["public"]["Enums"]["offer_decline_reason"]
            | null
          expires_at?: string
          extended_by?: string | null
          extension_reason?: string | null
          id?: string
          issued_at?: string
          issued_by?: string | null
          responded_at?: string | null
          section_id?: string | null
          status?: Database["public"]["Enums"]["offer_status"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "admission_offer_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "admission_application"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_offer_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_offer_extended_by_fkey"
            columns: ["extended_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_offer_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "admission_offer_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "class_section"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admission_offer_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_section_seat_availability"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "admission_offer_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_unallocated_section_subject"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "admission_offer_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      app_user: {
        Row: {
          app_role: Database["public"]["Enums"]["app_role"]
          claims_version: number
          created_at: string
          full_name: string
          phone_e164: string | null
          status: Database["public"]["Enums"]["user_status"]
          tenant_id: string
          user_id: string
        }
        Insert: {
          app_role: Database["public"]["Enums"]["app_role"]
          claims_version?: number
          created_at?: string
          full_name: string
          phone_e164?: string | null
          status?: Database["public"]["Enums"]["user_status"]
          tenant_id: string
          user_id: string
        }
        Update: {
          app_role?: Database["public"]["Enums"]["app_role"]
          claims_version?: number
          created_at?: string
          full_name?: string
          phone_e164?: string | null
          status?: Database["public"]["Enums"]["user_status"]
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "app_user_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      application_no_counter: {
        Row: {
          campus_id: string
          next_seq: number
          session_id: string
        }
        Insert: {
          campus_id: string
          next_seq?: number
          session_id: string
        }
        Update: {
          campus_id?: string
          next_seq?: number
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "application_no_counter_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "application_no_counter_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role: Database["public"]["Enums"]["app_role"] | null
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          campus_id: string | null
          changed_columns: string[] | null
          id: string
          occurred_at: string
          row_id: string | null
          table_name: string
          tenant_id: string
        }
        Insert: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name: string
          tenant_id: string
        }
        Update: {
          action?: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name?: string
          tenant_id?: string
        }
        Relationships: []
      }
      audit_log_2026_07: {
        Row: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role: Database["public"]["Enums"]["app_role"] | null
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          campus_id: string | null
          changed_columns: string[] | null
          id: string
          occurred_at: string
          row_id: string | null
          table_name: string
          tenant_id: string
        }
        Insert: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name: string
          tenant_id: string
        }
        Update: {
          action?: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name?: string
          tenant_id?: string
        }
        Relationships: []
      }
      audit_log_2026_08: {
        Row: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role: Database["public"]["Enums"]["app_role"] | null
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          campus_id: string | null
          changed_columns: string[] | null
          id: string
          occurred_at: string
          row_id: string | null
          table_name: string
          tenant_id: string
        }
        Insert: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name: string
          tenant_id: string
        }
        Update: {
          action?: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name?: string
          tenant_id?: string
        }
        Relationships: []
      }
      audit_log_2026_09: {
        Row: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role: Database["public"]["Enums"]["app_role"] | null
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          campus_id: string | null
          changed_columns: string[] | null
          id: string
          occurred_at: string
          row_id: string | null
          table_name: string
          tenant_id: string
        }
        Insert: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name: string
          tenant_id: string
        }
        Update: {
          action?: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name?: string
          tenant_id?: string
        }
        Relationships: []
      }
      audit_log_default: {
        Row: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role: Database["public"]["Enums"]["app_role"] | null
          actor_user_id: string | null
          after: Json | null
          before: Json | null
          campus_id: string | null
          changed_columns: string[] | null
          id: string
          occurred_at: string
          row_id: string | null
          table_name: string
          tenant_id: string
        }
        Insert: {
          action: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name: string
          tenant_id: string
        }
        Update: {
          action?: Database["public"]["Enums"]["audit_action"]
          actor_role?: Database["public"]["Enums"]["app_role"] | null
          actor_user_id?: string | null
          after?: Json | null
          before?: Json | null
          campus_id?: string | null
          changed_columns?: string[] | null
          id?: string
          occurred_at?: string
          row_id?: string | null
          table_name?: string
          tenant_id?: string
        }
        Relationships: []
      }
      audit_redacted_column: {
        Row: {
          column_name: string
          table_name: string
        }
        Insert: {
          column_name: string
          table_name: string
        }
        Update: {
          column_name?: string
          table_name?: string
        }
        Relationships: []
      }
      campus: {
        Row: {
          address_line: string | null
          city: string | null
          code: string
          created_at: string
          day_end: string
          day_start: string
          deleted_at: string | null
          district: string | null
          id: string
          name: string
          name_ur: string | null
          phone_e164: string | null
          status: Database["public"]["Enums"]["campus_status"]
          tenant_id: string
          timezone: string
          working_days: number[]
        }
        Insert: {
          address_line?: string | null
          city?: string | null
          code: string
          created_at?: string
          day_end?: string
          day_start?: string
          deleted_at?: string | null
          district?: string | null
          id?: string
          name: string
          name_ur?: string | null
          phone_e164?: string | null
          status?: Database["public"]["Enums"]["campus_status"]
          tenant_id: string
          timezone?: string
          working_days?: number[]
        }
        Update: {
          address_line?: string | null
          city?: string | null
          code?: string
          created_at?: string
          day_end?: string
          day_start?: string
          deleted_at?: string | null
          district?: string | null
          id?: string
          name?: string
          name_ur?: string | null
          phone_e164?: string | null
          status?: Database["public"]["Enums"]["campus_status"]
          tenant_id?: string
          timezone?: string
          working_days?: number[]
        }
        Relationships: [
          {
            foreignKeyName: "campus_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      campus_bank_account: {
        Row: {
          account_no: string
          bank_name: string
          branch_code: string | null
          campus_id: string
          created_at: string
          iban: string | null
          id: string
          is_default: boolean
          title: string
        }
        Insert: {
          account_no: string
          bank_name: string
          branch_code?: string | null
          campus_id: string
          created_at?: string
          iban?: string | null
          id?: string
          is_default?: boolean
          title: string
        }
        Update: {
          account_no?: string
          bank_name?: string
          branch_code?: string | null
          campus_id?: string
          created_at?: string
          iban?: string | null
          id?: string
          is_default?: boolean
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "campus_bank_account_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
        ]
      }
      campus_setting: {
        Row: {
          campus_id: string
          created_at: string
          key: string
          value: Json
        }
        Insert: {
          campus_id: string
          created_at?: string
          key: string
          value: Json
        }
        Update: {
          campus_id?: string
          created_at?: string
          key?: string
          value?: Json
        }
        Relationships: [
          {
            foreignKeyName: "campus_setting_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_book_day: {
        Row: {
          book_date: string
          campus_id: string
          closing_paisa: number
          disbursements_paisa: number
          finalised_at: string
          finalised_by: string | null
          opening_paisa: number
          receipts_paisa: number
          tenant_id: string
        }
        Insert: {
          book_date: string
          campus_id: string
          closing_paisa: number
          disbursements_paisa: number
          finalised_at?: string
          finalised_by?: string | null
          opening_paisa: number
          receipts_paisa: number
          tenant_id: string
        }
        Update: {
          book_date?: string
          campus_id?: string
          closing_paisa?: number
          disbursements_paisa?: number
          finalised_at?: string
          finalised_by?: string | null
          opening_paisa?: number
          receipts_paisa?: number
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_book_day_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_book_day_finalised_by_fkey"
            columns: ["finalised_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "cash_book_day_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      challan_counter: {
        Row: {
          campus_id: string
          last_no: number
          session_id: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          last_no?: number
          session_id: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          last_no?: number
          session_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "challan_counter_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challan_counter_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challan_counter_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      challan_template: {
        Row: {
          bank_account_no: string
          bank_account_title: string
          bank_name: string
          campus_id: string
          footer_note_en: string | null
          footer_note_ur: string | null
          logo_path: string | null
          tenant_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          bank_account_no: string
          bank_account_title: string
          bank_name: string
          campus_id: string
          footer_note_en?: string | null
          footer_note_ur?: string | null
          logo_path?: string | null
          tenant_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          bank_account_no?: string
          bank_account_title?: string
          bank_name?: string
          campus_id?: string
          footer_note_en?: string | null
          footer_note_ur?: string | null
          logo_path?: string | null
          tenant_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "challan_template_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: true
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challan_template_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "challan_template_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      class_level: {
        Row: {
          board_stage: string | null
          code: string
          created_at: string
          id: string
          is_active: boolean
          name_en: string
          name_ur: string | null
          ordinal: number
          tenant_id: string
        }
        Insert: {
          board_stage?: string | null
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name_en: string
          name_ur?: string | null
          ordinal: number
          tenant_id: string
        }
        Update: {
          board_stage?: string | null
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name_en?: string
          name_ur?: string | null
          ordinal?: number
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "class_level_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      class_section: {
        Row: {
          campus_id: string
          capacity: number
          class_level_id: string
          created_at: string
          gender_restriction: Database["public"]["Enums"]["gender"] | null
          id: string
          is_active: boolean
          medium: Database["public"]["Enums"]["section_medium"]
          name: string
          session_id: string
          shift: Database["public"]["Enums"]["section_shift"]
          stream_id: string | null
          tenant_id: string
        }
        Insert: {
          campus_id: string
          capacity: number
          class_level_id: string
          created_at?: string
          gender_restriction?: Database["public"]["Enums"]["gender"] | null
          id?: string
          is_active?: boolean
          medium?: Database["public"]["Enums"]["section_medium"]
          name: string
          session_id: string
          shift?: Database["public"]["Enums"]["section_shift"]
          stream_id?: string | null
          tenant_id: string
        }
        Update: {
          campus_id?: string
          capacity?: number
          class_level_id?: string
          created_at?: string
          gender_restriction?: Database["public"]["Enums"]["gender"] | null
          id?: string
          is_active?: boolean
          medium?: Database["public"]["Enums"]["section_medium"]
          name?: string
          session_id?: string
          shift?: Database["public"]["Enums"]["section_shift"]
          stream_id?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "class_section_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_section_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_section_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_section_stream_id_fkey"
            columns: ["stream_id"]
            isOneToOne: false
            referencedRelation: "stream"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_section_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      class_subject: {
        Row: {
          campus_id: string
          choose_n: number | null
          class_level_id: string
          created_at: string
          elective_bucket: number | null
          id: string
          is_compulsory: boolean
          max_marks: number | null
          session_id: string
          stream_id: string | null
          subject_id: string
          tenant_id: string
          weekly_periods: number
        }
        Insert: {
          campus_id: string
          choose_n?: number | null
          class_level_id: string
          created_at?: string
          elective_bucket?: number | null
          id?: string
          is_compulsory?: boolean
          max_marks?: number | null
          session_id: string
          stream_id?: string | null
          subject_id: string
          tenant_id: string
          weekly_periods: number
        }
        Update: {
          campus_id?: string
          choose_n?: number | null
          class_level_id?: string
          created_at?: string
          elective_bucket?: number | null
          id?: string
          is_compulsory?: boolean
          max_marks?: number | null
          session_id?: string
          stream_id?: string | null
          subject_id?: string
          tenant_id?: string
          weekly_periods?: number
        }
        Relationships: [
          {
            foreignKeyName: "class_subject_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_stream_id_fkey"
            columns: ["stream_id"]
            isOneToOne: false
            referencedRelation: "stream"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subject"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      concession_award: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          calc_type: Database["public"]["Enums"]["concession_calc_type"]
          campus_id: string
          created_at: string
          effective_from: string
          effective_to: string
          enrolment_id: string
          id: string
          rejection_reason: string | null
          requested_by: string | null
          scheme_id: string
          status: Database["public"]["Enums"]["concession_award_status"]
          tenant_id: string
          value: number
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          calc_type: Database["public"]["Enums"]["concession_calc_type"]
          campus_id: string
          created_at?: string
          effective_from: string
          effective_to: string
          enrolment_id: string
          id?: string
          rejection_reason?: string | null
          requested_by?: string | null
          scheme_id: string
          status?: Database["public"]["Enums"]["concession_award_status"]
          tenant_id: string
          value: number
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          calc_type?: Database["public"]["Enums"]["concession_calc_type"]
          campus_id?: string
          created_at?: string
          effective_from?: string
          effective_to?: string
          enrolment_id?: string
          id?: string
          rejection_reason?: string | null
          requested_by?: string | null
          scheme_id?: string
          status?: Database["public"]["Enums"]["concession_award_status"]
          tenant_id?: string
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "concession_award_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "concession_award_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "concession_award_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "concession_award_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "concession_award_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "concession_award_scheme_id_fkey"
            columns: ["scheme_id"]
            isOneToOne: false
            referencedRelation: "concession_scheme"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "concession_award_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      concession_award_document: {
        Row: {
          award_id: string
          doc_type: string | null
          id: string
          storage_path: string
          uploaded_at: string
          uploaded_by: string | null
        }
        Insert: {
          award_id: string
          doc_type?: string | null
          id?: string
          storage_path: string
          uploaded_at?: string
          uploaded_by?: string | null
        }
        Update: {
          award_id?: string
          doc_type?: string | null
          id?: string
          storage_path?: string
          uploaded_at?: string
          uploaded_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "concession_award_document_award_id_fkey"
            columns: ["award_id"]
            isOneToOne: false
            referencedRelation: "concession_award"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "concession_award_document_uploaded_by_fkey"
            columns: ["uploaded_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      concession_scheme: {
        Row: {
          applicable_head_ids: string[]
          approver_role: Database["public"]["Enums"]["app_role"]
          calc_type: Database["public"]["Enums"]["concession_calc_type"]
          category: string | null
          code: string
          created_at: string
          created_by: string | null
          default_validity_months: number
          id: string
          is_active: boolean
          max_value: number | null
          name_en: string
          name_ur: string
          requires_document: boolean
          tenant_id: string
          value: number
        }
        Insert: {
          applicable_head_ids: string[]
          approver_role?: Database["public"]["Enums"]["app_role"]
          calc_type: Database["public"]["Enums"]["concession_calc_type"]
          category?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          default_validity_months?: number
          id?: string
          is_active?: boolean
          max_value?: number | null
          name_en: string
          name_ur: string
          requires_document?: boolean
          tenant_id: string
          value: number
        }
        Update: {
          applicable_head_ids?: string[]
          approver_role?: Database["public"]["Enums"]["app_role"]
          calc_type?: Database["public"]["Enums"]["concession_calc_type"]
          category?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          default_validity_months?: number
          id?: string
          is_active?: boolean
          max_value?: number | null
          name_en?: string
          name_ur?: string
          requires_document?: boolean
          tenant_id?: string
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "concession_scheme_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "concession_scheme_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      department: {
        Row: {
          code: string
          id: string
          name_en: string
          name_ur: string | null
          tenant_id: string
        }
        Insert: {
          code: string
          id?: string
          name_en: string
          name_ur?: string | null
          tenant_id: string
        }
        Update: {
          code?: string
          id?: string
          name_en?: string
          name_ur?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "department_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      designation: {
        Row: {
          code: string
          id: string
          name_en: string
          name_ur: string | null
          tenant_id: string
        }
        Insert: {
          code: string
          id?: string
          name_en: string
          name_ur?: string | null
          tenant_id: string
        }
        Update: {
          code?: string
          id?: string
          name_en?: string
          name_ur?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "designation_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_code_counter: {
        Row: {
          campus_id: string
          next_value: number
        }
        Insert: {
          campus_id: string
          next_value?: number
        }
        Update: {
          campus_id?: string
          next_value?: number
        }
        Relationships: [
          {
            foreignKeyName: "employee_code_counter_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: true
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
        ]
      }
      enquiry_duplicate_dismissed: {
        Row: {
          dismissed_at: string
          dismissed_by: string | null
          enquiry_a: string
          enquiry_b: string
          tenant_id: string
        }
        Insert: {
          dismissed_at?: string
          dismissed_by?: string | null
          enquiry_a: string
          enquiry_b: string
          tenant_id: string
        }
        Update: {
          dismissed_at?: string
          dismissed_by?: string | null
          enquiry_a?: string
          enquiry_b?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "enquiry_duplicate_dismissed_dismissed_by_fkey"
            columns: ["dismissed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "enquiry_duplicate_dismissed_enquiry_a_fkey"
            columns: ["enquiry_a"]
            isOneToOne: false
            referencedRelation: "admission_enquiry"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enquiry_duplicate_dismissed_enquiry_b_fkey"
            columns: ["enquiry_b"]
            isOneToOne: false
            referencedRelation: "admission_enquiry"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enquiry_duplicate_dismissed_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      enquiry_no_counter: {
        Row: {
          campus_id: string
          next_seq: number
          session_id: string
        }
        Insert: {
          campus_id: string
          next_seq?: number
          session_id: string
        }
        Update: {
          campus_id?: string
          next_seq?: number
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "enquiry_no_counter_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enquiry_no_counter_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
        ]
      }
      enrolment: {
        Row: {
          campus_id: string
          class_level_id: string
          created_at: string
          id: string
          joined_on: string
          left_on: string | null
          over_capacity: boolean
          override_at: string | null
          override_by: string | null
          override_reason: string | null
          previous_enrolment_id: string | null
          roll_no: number | null
          section_id: string
          session_id: string
          status: Database["public"]["Enums"]["enrolment_status"]
          student_id: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          class_level_id: string
          created_at?: string
          id?: string
          joined_on?: string
          left_on?: string | null
          over_capacity?: boolean
          override_at?: string | null
          override_by?: string | null
          override_reason?: string | null
          previous_enrolment_id?: string | null
          roll_no?: number | null
          section_id: string
          session_id: string
          status?: Database["public"]["Enums"]["enrolment_status"]
          student_id: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          class_level_id?: string
          created_at?: string
          id?: string
          joined_on?: string
          left_on?: string | null
          over_capacity?: boolean
          override_at?: string | null
          override_by?: string | null
          override_reason?: string | null
          previous_enrolment_id?: string | null
          roll_no?: number | null
          section_id?: string
          session_id?: string
          status?: Database["public"]["Enums"]["enrolment_status"]
          student_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "enrolment_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_override_by_fkey"
            columns: ["override_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "enrolment_previous_enrolment_id_fkey"
            columns: ["previous_enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_previous_enrolment_id_fkey"
            columns: ["previous_enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "enrolment_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "class_section"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_section_seat_availability"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "enrolment_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_unallocated_section_subject"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "enrolment_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "enrolment_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "enrolment_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      family_group: {
        Row: {
          confirmed_at: string | null
          confirmed_by: string | null
          created_at: string
          father_cnic: string | null
          id: string
          primary_guardian_id: string | null
          tenant_id: string
        }
        Insert: {
          confirmed_at?: string | null
          confirmed_by?: string | null
          created_at?: string
          father_cnic?: string | null
          id?: string
          primary_guardian_id?: string | null
          tenant_id: string
        }
        Update: {
          confirmed_at?: string | null
          confirmed_by?: string | null
          created_at?: string
          father_cnic?: string | null
          id?: string
          primary_guardian_id?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "family_group_confirmed_by_fkey"
            columns: ["confirmed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "family_group_primary_guardian_id_fkey"
            columns: ["primary_guardian_id"]
            isOneToOne: false
            referencedRelation: "guardian"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "family_group_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_challan: {
        Row: {
          arrears_paisa: number
          batch_id: string | null
          billing_period: string
          campus_id: string
          challan_no: string
          concession_paisa: number
          created_at: string
          due_date: string
          enrolment_id: string
          gross_paisa: number
          id: string
          issue_date: string
          net_paisa: number
          session_id: string
          status: Database["public"]["Enums"]["fee_challan_status"]
          tenant_id: string
        }
        Insert: {
          arrears_paisa?: number
          batch_id?: string | null
          billing_period: string
          campus_id: string
          challan_no: string
          concession_paisa?: number
          created_at?: string
          due_date: string
          enrolment_id: string
          gross_paisa: number
          id?: string
          issue_date?: string
          net_paisa: number
          session_id: string
          status?: Database["public"]["Enums"]["fee_challan_status"]
          tenant_id: string
        }
        Update: {
          arrears_paisa?: number
          batch_id?: string | null
          billing_period?: string
          campus_id?: string
          challan_no?: string
          concession_paisa?: number
          created_at?: string
          due_date?: string
          enrolment_id?: string
          gross_paisa?: number
          id?: string
          issue_date?: string
          net_paisa?: number
          session_id?: string
          status?: Database["public"]["Enums"]["fee_challan_status"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_challan_batch_id_fkey"
            columns: ["batch_id"]
            isOneToOne: false
            referencedRelation: "fee_challan_batch"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "fee_challan_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_challan_batch: {
        Row: {
          billing_period: string
          campus_id: string
          completed_at: string | null
          failed_count: number
          generated_count: number
          id: string
          requested_by: string | null
          session_id: string
          skipped_count: number
          started_at: string
          tenant_id: string
        }
        Insert: {
          billing_period: string
          campus_id: string
          completed_at?: string | null
          failed_count?: number
          generated_count?: number
          id?: string
          requested_by?: string | null
          session_id: string
          skipped_count?: number
          started_at?: string
          tenant_id: string
        }
        Update: {
          billing_period?: string
          campus_id?: string
          completed_at?: string | null
          failed_count?: number
          generated_count?: number
          id?: string
          requested_by?: string | null
          session_id?: string
          skipped_count?: number
          started_at?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_challan_batch_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_batch_requested_by_fkey"
            columns: ["requested_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_challan_batch_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_batch_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_challan_batch_error: {
        Row: {
          batch_id: string
          created_at: string
          enrolment_id: string
          id: string
          reason: string
        }
        Insert: {
          batch_id: string
          created_at?: string
          enrolment_id: string
          id?: string
          reason: string
        }
        Update: {
          batch_id?: string
          created_at?: string
          enrolment_id?: string
          id?: string
          reason?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_challan_batch_error_batch_id_fkey"
            columns: ["batch_id"]
            isOneToOne: false
            referencedRelation: "fee_challan_batch"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_batch_error_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_batch_error_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
        ]
      }
      fee_challan_line: {
        Row: {
          amount_paisa: number
          applied_award_ids: string[] | null
          challan_id: string
          concession_paisa: number
          fee_head_id: string
          id: string
          line_type: Database["public"]["Enums"]["fee_challan_line_type"]
          net_paisa: number
        }
        Insert: {
          amount_paisa: number
          applied_award_ids?: string[] | null
          challan_id: string
          concession_paisa?: number
          fee_head_id: string
          id?: string
          line_type: Database["public"]["Enums"]["fee_challan_line_type"]
          net_paisa: number
        }
        Update: {
          amount_paisa?: number
          applied_award_ids?: string[] | null
          challan_id?: string
          concession_paisa?: number
          fee_head_id?: string
          id?: string
          line_type?: Database["public"]["Enums"]["fee_challan_line_type"]
          net_paisa?: number
        }
        Relationships: [
          {
            foreignKeyName: "fee_challan_line_challan_id_fkey"
            columns: ["challan_id"]
            isOneToOne: false
            referencedRelation: "fee_challan"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_challan_line_fee_head_id_fkey"
            columns: ["fee_head_id"]
            isOneToOne: false
            referencedRelation: "fee_head"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_challan_pdf: {
        Row: {
          challan_id: string
          id: string
          rendered_at: string
          sha256: string
          storage_path: string
          template_version: number
        }
        Insert: {
          challan_id: string
          id?: string
          rendered_at?: string
          sha256: string
          storage_path: string
          template_version?: number
        }
        Update: {
          challan_id?: string
          id?: string
          rendered_at?: string
          sha256?: string
          storage_path?: string
          template_version?: number
        }
        Relationships: [
          {
            foreignKeyName: "fee_challan_pdf_challan_id_fkey"
            columns: ["challan_id"]
            isOneToOne: false
            referencedRelation: "fee_challan"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_head: {
        Row: {
          carry_forward_on_arrears: boolean
          code: string
          created_at: string
          created_by: string | null
          default_frequency: Database["public"]["Enums"]["fee_frequency"]
          gl_code: string | null
          id: string
          is_active: boolean
          is_mandatory: boolean
          is_refundable: boolean
          name_en: string
          name_ur: string
          tenant_id: string
        }
        Insert: {
          carry_forward_on_arrears?: boolean
          code: string
          created_at?: string
          created_by?: string | null
          default_frequency?: Database["public"]["Enums"]["fee_frequency"]
          gl_code?: string | null
          id?: string
          is_active?: boolean
          is_mandatory?: boolean
          is_refundable?: boolean
          name_en: string
          name_ur: string
          tenant_id: string
        }
        Update: {
          carry_forward_on_arrears?: boolean
          code?: string
          created_at?: string
          created_by?: string | null
          default_frequency?: Database["public"]["Enums"]["fee_frequency"]
          gl_code?: string | null
          id?: string
          is_active?: boolean
          is_mandatory?: boolean
          is_refundable?: boolean
          name_en?: string
          name_ur?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_head_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_head_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_head_priority: {
        Row: {
          fee_head_id: string
          priority: number
          tenant_id: string
        }
        Insert: {
          fee_head_id: string
          priority: number
          tenant_id: string
        }
        Update: {
          fee_head_id?: string
          priority?: number
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_head_priority_fee_head_id_fkey"
            columns: ["fee_head_id"]
            isOneToOne: false
            referencedRelation: "fee_head"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_head_priority_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_increase_approval: {
        Row: {
          approved_at: string
          approver_id: string | null
          avg_increase_pct: number
          id: string
          regulator_reference: string
          structure_id: string
        }
        Insert: {
          approved_at?: string
          approver_id?: string | null
          avg_increase_pct: number
          id?: string
          regulator_reference: string
          structure_id: string
        }
        Update: {
          approved_at?: string
          approver_id?: string | null
          avg_increase_pct?: number
          id?: string
          regulator_reference?: string
          structure_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_increase_approval_approver_id_fkey"
            columns: ["approver_id"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_increase_approval_structure_id_fkey"
            columns: ["structure_id"]
            isOneToOne: false
            referencedRelation: "fee_structure"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_job_run: {
        Row: {
          completed_at: string | null
          duration_ms: number | null
          error_text: string | null
          id: string
          job_name: string
          rows_written: number
          run_date: string
          started_at: string
          status: string
        }
        Insert: {
          completed_at?: string | null
          duration_ms?: number | null
          error_text?: string | null
          id?: string
          job_name: string
          rows_written?: number
          run_date: string
          started_at?: string
          status?: string
        }
        Update: {
          completed_at?: string | null
          duration_ms?: number | null
          error_text?: string | null
          id?: string
          job_name?: string
          rows_written?: number
          run_date?: string
          started_at?: string
          status?: string
        }
        Relationships: []
      }
      fee_ledger: {
        Row: {
          amount_paisa: number
          campus_id: string
          challan_id: string | null
          created_by: string | null
          direction: Database["public"]["Enums"]["fee_ledger_direction"]
          enrolment_id: string
          entry_type: Database["public"]["Enums"]["fee_ledger_entry_type"]
          fee_head_id: string | null
          id: string
          posted_at: string
          reason: string | null
          reversal_of_id: string | null
          session_id: string
          source_id: string | null
          source_type: string | null
          tenant_id: string
          value_date: string
        }
        Insert: {
          amount_paisa: number
          campus_id: string
          challan_id?: string | null
          created_by?: string | null
          direction: Database["public"]["Enums"]["fee_ledger_direction"]
          enrolment_id: string
          entry_type: Database["public"]["Enums"]["fee_ledger_entry_type"]
          fee_head_id?: string | null
          id?: string
          posted_at?: string
          reason?: string | null
          reversal_of_id?: string | null
          session_id: string
          source_id?: string | null
          source_type?: string | null
          tenant_id: string
          value_date?: string
        }
        Update: {
          amount_paisa?: number
          campus_id?: string
          challan_id?: string | null
          created_by?: string | null
          direction?: Database["public"]["Enums"]["fee_ledger_direction"]
          enrolment_id?: string
          entry_type?: Database["public"]["Enums"]["fee_ledger_entry_type"]
          fee_head_id?: string | null
          id?: string
          posted_at?: string
          reason?: string | null
          reversal_of_id?: string | null
          session_id?: string
          source_id?: string | null
          source_type?: string | null
          tenant_id?: string
          value_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_ledger_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_challan_id_fkey"
            columns: ["challan_id"]
            isOneToOne: false
            referencedRelation: "fee_challan"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_ledger_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "fee_ledger_fee_head_id_fkey"
            columns: ["fee_head_id"]
            isOneToOne: false
            referencedRelation: "fee_head"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_reversal_of_id_fkey"
            columns: ["reversal_of_id"]
            isOneToOne: false
            referencedRelation: "fee_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_reversal_of_id_fkey"
            columns: ["reversal_of_id"]
            isOneToOne: false
            referencedRelation: "v_daily_collection"
            referencedColumns: ["ledger_id"]
          },
          {
            foreignKeyName: "fee_ledger_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_payment: {
        Row: {
          amount_paisa: number
          campus_id: string
          collected_by: string | null
          enrolment_id: string
          id: string
          mode: Database["public"]["Enums"]["fee_payment_mode"]
          received_at: string
          reference_no: string | null
          tenant_id: string
          value_date: string
        }
        Insert: {
          amount_paisa: number
          campus_id: string
          collected_by?: string | null
          enrolment_id: string
          id?: string
          mode: Database["public"]["Enums"]["fee_payment_mode"]
          received_at?: string
          reference_no?: string | null
          tenant_id: string
          value_date?: string
        }
        Update: {
          amount_paisa?: number
          campus_id?: string
          collected_by?: string | null
          enrolment_id?: string
          id?: string
          mode?: Database["public"]["Enums"]["fee_payment_mode"]
          received_at?: string
          reference_no?: string | null
          tenant_id?: string
          value_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_payment_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_payment_collected_by_fkey"
            columns: ["collected_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_payment_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_payment_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "fee_payment_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_payment_allocation: {
        Row: {
          amount_paisa: number
          challan_id: string
          created_at: string
          fee_head_id: string
          id: string
          payment_id: string
        }
        Insert: {
          amount_paisa: number
          challan_id: string
          created_at?: string
          fee_head_id: string
          id?: string
          payment_id: string
        }
        Update: {
          amount_paisa?: number
          challan_id?: string
          created_at?: string
          fee_head_id?: string
          id?: string
          payment_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_payment_allocation_challan_id_fkey"
            columns: ["challan_id"]
            isOneToOne: false
            referencedRelation: "fee_challan"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_payment_allocation_fee_head_id_fkey"
            columns: ["fee_head_id"]
            isOneToOne: false
            referencedRelation: "fee_head"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_payment_allocation_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "fee_payment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_payment_allocation_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "v_daily_collection"
            referencedColumns: ["payment_id"]
          },
        ]
      }
      fee_plan: {
        Row: {
          campus_id: string
          created_at: string
          effective_from: string
          enrolment_id: string
          id: string
          session_id: string
          structure_id: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          created_at?: string
          effective_from?: string
          enrolment_id: string
          id?: string
          session_id: string
          structure_id: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          created_at?: string
          effective_from?: string
          enrolment_id?: string
          id?: string
          session_id?: string
          structure_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_plan_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_plan_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: true
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_plan_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: true
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "fee_plan_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_plan_structure_id_fkey"
            columns: ["structure_id"]
            isOneToOne: false
            referencedRelation: "fee_structure"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_plan_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_plan_line: {
        Row: {
          amount_paisa: number
          approved_at: string | null
          approved_by: string | null
          billing_month_mask: number
          created_at: string
          effective_from: string
          effective_to: string | null
          fee_head_id: string
          frequency: Database["public"]["Enums"]["fee_frequency"]
          id: string
          override_reason: string | null
          override_status: Database["public"]["Enums"]["fee_plan_override_status"]
          pending_amount_paisa: number | null
          plan_id: string
          source_structure_line_id: string | null
        }
        Insert: {
          amount_paisa: number
          approved_at?: string | null
          approved_by?: string | null
          billing_month_mask: number
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          fee_head_id: string
          frequency: Database["public"]["Enums"]["fee_frequency"]
          id?: string
          override_reason?: string | null
          override_status?: Database["public"]["Enums"]["fee_plan_override_status"]
          pending_amount_paisa?: number | null
          plan_id: string
          source_structure_line_id?: string | null
        }
        Update: {
          amount_paisa?: number
          approved_at?: string | null
          approved_by?: string | null
          billing_month_mask?: number
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          fee_head_id?: string
          frequency?: Database["public"]["Enums"]["fee_frequency"]
          id?: string
          override_reason?: string | null
          override_status?: Database["public"]["Enums"]["fee_plan_override_status"]
          pending_amount_paisa?: number | null
          plan_id?: string
          source_structure_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fee_plan_line_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_plan_line_fee_head_id_fkey"
            columns: ["fee_head_id"]
            isOneToOne: false
            referencedRelation: "fee_head"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_plan_line_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "fee_plan"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_plan_line_source_structure_line_id_fkey"
            columns: ["source_structure_line_id"]
            isOneToOne: false
            referencedRelation: "fee_structure_line"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_policy: {
        Row: {
          allow_negative_net: boolean
          max_fee_increase_pct: number | null
          max_stacked_concession_pct: number | null
          tenant_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allow_negative_net?: boolean
          max_fee_increase_pct?: number | null
          max_stacked_concession_pct?: number | null
          tenant_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allow_negative_net?: boolean
          max_fee_increase_pct?: number | null
          max_stacked_concession_pct?: number | null
          tenant_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fee_policy_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: true
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_policy_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      fee_receipt: {
        Row: {
          campus_id: string
          client_idempotency_key: string | null
          counter_session_id: string | null
          created_at: string
          id: string
          payment_id: string
          printed_count: number
          receipt_no: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          client_idempotency_key?: string | null
          counter_session_id?: string | null
          created_at?: string
          id?: string
          payment_id: string
          printed_count?: number
          receipt_no: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          client_idempotency_key?: string | null
          counter_session_id?: string | null
          created_at?: string
          id?: string
          payment_id?: string
          printed_count?: number
          receipt_no?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_receipt_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_receipt_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "fee_payment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_receipt_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "v_daily_collection"
            referencedColumns: ["payment_id"]
          },
          {
            foreignKeyName: "fee_receipt_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_receipt_counter: {
        Row: {
          campus_id: string
          last_no: number
          session_id: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          last_no?: number
          session_id: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          last_no?: number
          session_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_receipt_counter_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_receipt_counter_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_receipt_counter_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_receipt_print_log: {
        Row: {
          id: string
          printed_at: string
          printed_by: string | null
          receipt_id: string
        }
        Insert: {
          id?: string
          printed_at?: string
          printed_by?: string | null
          receipt_id: string
        }
        Update: {
          id?: string
          printed_at?: string
          printed_by?: string | null
          receipt_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_receipt_print_log_printed_by_fkey"
            columns: ["printed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_receipt_print_log_receipt_id_fkey"
            columns: ["receipt_id"]
            isOneToOne: false
            referencedRelation: "fee_receipt"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_structure: {
        Row: {
          approved_by: string | null
          campus_id: string
          created_at: string
          created_by: string | null
          effective_from: string
          id: string
          published_at: string | null
          published_by: string | null
          regulator_reference: string | null
          session_id: string
          status: Database["public"]["Enums"]["fee_structure_status"]
          supersedes_id: string | null
          tenant_id: string
          version_no: number
        }
        Insert: {
          approved_by?: string | null
          campus_id: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          id?: string
          published_at?: string | null
          published_by?: string | null
          regulator_reference?: string | null
          session_id: string
          status?: Database["public"]["Enums"]["fee_structure_status"]
          supersedes_id?: string | null
          tenant_id: string
          version_no?: number
        }
        Update: {
          approved_by?: string | null
          campus_id?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          id?: string
          published_at?: string | null
          published_by?: string | null
          regulator_reference?: string | null
          session_id?: string
          status?: Database["public"]["Enums"]["fee_structure_status"]
          supersedes_id?: string | null
          tenant_id?: string
          version_no?: number
        }
        Relationships: [
          {
            foreignKeyName: "fee_structure_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_structure_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_structure_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_structure_published_by_fkey"
            columns: ["published_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "fee_structure_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_structure_supersedes_id_fkey"
            columns: ["supersedes_id"]
            isOneToOne: false
            referencedRelation: "fee_structure"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_structure_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_structure_line: {
        Row: {
          amount_paisa: number
          billing_month_mask: number
          class_id: string
          created_at: string
          fee_head_id: string
          frequency: Database["public"]["Enums"]["fee_frequency"]
          group_code: string | null
          id: string
          structure_id: string
        }
        Insert: {
          amount_paisa: number
          billing_month_mask?: number
          class_id: string
          created_at?: string
          fee_head_id: string
          frequency: Database["public"]["Enums"]["fee_frequency"]
          group_code?: string | null
          id?: string
          structure_id: string
        }
        Update: {
          amount_paisa?: number
          billing_month_mask?: number
          class_id?: string
          created_at?: string
          fee_head_id?: string
          frequency?: Database["public"]["Enums"]["fee_frequency"]
          group_code?: string | null
          id?: string
          structure_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_structure_line_class_id_fkey"
            columns: ["class_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_structure_line_fee_head_id_fkey"
            columns: ["fee_head_id"]
            isOneToOne: false
            referencedRelation: "fee_head"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_structure_line_structure_id_fkey"
            columns: ["structure_id"]
            isOneToOne: false
            referencedRelation: "fee_structure"
            referencedColumns: ["id"]
          },
        ]
      }
      gr_ledger: {
        Row: {
          allocated_at: string
          allocated_by: string | null
          campus_id: string
          gr_number: string
          student_id: string | null
        }
        Insert: {
          allocated_at?: string
          allocated_by?: string | null
          campus_id: string
          gr_number: string
          student_id?: string | null
        }
        Update: {
          allocated_at?: string
          allocated_by?: string | null
          campus_id?: string
          gr_number?: string
          student_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "gr_ledger_allocated_by_fkey"
            columns: ["allocated_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "gr_ledger_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gr_ledger_student_fk"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gr_ledger_student_fk"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "gr_ledger_student_fk"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
        ]
      }
      gr_sequence: {
        Row: {
          campus_id: string
          next_value: number
          pad_width: number
          prefix: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          next_value?: number
          pad_width?: number
          prefix: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          next_value?: number
          pad_width?: number
          prefix?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gr_sequence_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: true
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gr_sequence_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      guardian: {
        Row: {
          alt_phone: string | null
          auth_user_id: string | null
          cnic: string | null
          created_at: string
          email: string | null
          id: string
          name_en: string
          name_ur: string | null
          occupation: string | null
          phone_e164: string | null
          tenant_id: string
        }
        Insert: {
          alt_phone?: string | null
          auth_user_id?: string | null
          cnic?: string | null
          created_at?: string
          email?: string | null
          id?: string
          name_en: string
          name_ur?: string | null
          occupation?: string | null
          phone_e164?: string | null
          tenant_id: string
        }
        Update: {
          alt_phone?: string | null
          auth_user_id?: string | null
          cnic?: string | null
          created_at?: string
          email?: string | null
          id?: string
          name_en?: string
          name_ur?: string | null
          occupation?: string | null
          phone_e164?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "guardian_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      holiday_calendar: {
        Row: {
          campus_id: string | null
          holiday_date: string
          id: string
          name: string
          tenant_id: string
        }
        Insert: {
          campus_id?: string | null
          holiday_date: string
          id?: string
          name: string
          tenant_id: string
        }
        Update: {
          campus_id?: string | null
          holiday_date?: string
          id?: string
          name?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "holiday_calendar_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "holiday_calendar_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      late_fee_rule: {
        Row: {
          amount_paisa: number | null
          applicable_head_ids: string[] | null
          basis: Database["public"]["Enums"]["late_fee_basis"]
          campus_id: string
          cap_paisa: number | null
          created_at: string
          created_by: string | null
          effective_from: string
          exempt_concession_categories: string[] | null
          grace_days: number
          id: string
          max_days: number | null
          percentage: number | null
          session_id: string
          tenant_id: string
        }
        Insert: {
          amount_paisa?: number | null
          applicable_head_ids?: string[] | null
          basis: Database["public"]["Enums"]["late_fee_basis"]
          campus_id: string
          cap_paisa?: number | null
          created_at?: string
          created_by?: string | null
          effective_from?: string
          exempt_concession_categories?: string[] | null
          grace_days?: number
          id?: string
          max_days?: number | null
          percentage?: number | null
          session_id: string
          tenant_id: string
        }
        Update: {
          amount_paisa?: number | null
          applicable_head_ids?: string[] | null
          basis?: Database["public"]["Enums"]["late_fee_basis"]
          campus_id?: string
          cap_paisa?: number | null
          created_at?: string
          created_by?: string | null
          effective_from?: string
          exempt_concession_categories?: string[] | null
          grace_days?: number
          id?: string
          max_days?: number | null
          percentage?: number | null
          session_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "late_fee_rule_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "late_fee_rule_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "late_fee_rule_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "late_fee_rule_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_application: {
        Row: {
          campus_id: string
          decided_at: string | null
          decided_by: string | null
          decision_comment: string | null
          from_date: string
          id: string
          is_half_day: boolean
          leave_type_id: string
          reason: string | null
          staff_id: string
          status: Database["public"]["Enums"]["leave_application_status"]
          submitted_at: string
          tenant_id: string
          to_date: string
          working_days: number
        }
        Insert: {
          campus_id: string
          decided_at?: string | null
          decided_by?: string | null
          decision_comment?: string | null
          from_date: string
          id?: string
          is_half_day?: boolean
          leave_type_id: string
          reason?: string | null
          staff_id: string
          status?: Database["public"]["Enums"]["leave_application_status"]
          submitted_at?: string
          tenant_id: string
          to_date: string
          working_days: number
        }
        Update: {
          campus_id?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_comment?: string | null
          from_date?: string
          id?: string
          is_half_day?: boolean
          leave_type_id?: string
          reason?: string | null
          staff_id?: string
          status?: Database["public"]["Enums"]["leave_application_status"]
          submitted_at?: string
          tenant_id?: string
          to_date?: string
          working_days?: number
        }
        Relationships: [
          {
            foreignKeyName: "leave_application_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_application_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "leave_application_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "leave_type"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_application_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_application_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_approval_chain: {
        Row: {
          approver_role: Database["public"]["Enums"]["app_role"]
          approver_staff_id: string | null
          campus_id: string
          id: string
          leave_type_id: string
          sla_hours: number
          step_no: number
          tenant_id: string
        }
        Insert: {
          approver_role: Database["public"]["Enums"]["app_role"]
          approver_staff_id?: string | null
          campus_id: string
          id?: string
          leave_type_id: string
          sla_hours?: number
          step_no: number
          tenant_id: string
        }
        Update: {
          approver_role?: Database["public"]["Enums"]["app_role"]
          approver_staff_id?: string | null
          campus_id?: string
          id?: string
          leave_type_id?: string
          sla_hours?: number
          step_no?: number
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_approval_chain_approver_staff_id_fkey"
            columns: ["approver_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_approval_chain_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_approval_chain_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "leave_type"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_approval_chain_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_approval_step: {
        Row: {
          application_id: string
          approver_id: string | null
          comment: string | null
          created_at: string
          decided_at: string | null
          decision: Database["public"]["Enums"]["approval_decision"]
          effective_approver_role: Database["public"]["Enums"]["app_role"]
          id: string
          sla_due_at: string
          step_no: number
        }
        Insert: {
          application_id: string
          approver_id?: string | null
          comment?: string | null
          created_at?: string
          decided_at?: string | null
          decision?: Database["public"]["Enums"]["approval_decision"]
          effective_approver_role: Database["public"]["Enums"]["app_role"]
          id?: string
          sla_due_at: string
          step_no: number
        }
        Update: {
          application_id?: string
          approver_id?: string | null
          comment?: string | null
          created_at?: string
          decided_at?: string | null
          decision?: Database["public"]["Enums"]["approval_decision"]
          effective_approver_role?: Database["public"]["Enums"]["app_role"]
          id?: string
          sla_due_at?: string
          step_no?: number
        }
        Relationships: [
          {
            foreignKeyName: "leave_approval_step_application_id_fkey"
            columns: ["application_id"]
            isOneToOne: false
            referencedRelation: "leave_application"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_approval_step_approver_id_fkey"
            columns: ["approver_id"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      leave_ledger: {
        Row: {
          created_at: string
          created_by: string | null
          days: number
          entry_type: Database["public"]["Enums"]["leave_ledger_entry_type"]
          id: string
          leave_type_id: string
          reference_id: string | null
          staff_id: string
          tenant_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          days: number
          entry_type: Database["public"]["Enums"]["leave_ledger_entry_type"]
          id?: string
          leave_type_id: string
          reference_id?: string | null
          staff_id: string
          tenant_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          days?: number
          entry_type?: Database["public"]["Enums"]["leave_ledger_entry_type"]
          id?: string
          leave_type_id?: string
          reference_id?: string | null
          staff_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_ledger_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "leave_ledger_leave_type_id_fkey"
            columns: ["leave_type_id"]
            isOneToOne: false
            referencedRelation: "leave_type"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_ledger_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_ledger_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_type: {
        Row: {
          accrual_method: Database["public"]["Enums"]["leave_accrual_method"]
          carry_forward_cap_days: number | null
          code: string
          doc_required_after_days: number | null
          effective_from: string
          eligible_contract_types: string[]
          eligible_genders: string[]
          entitlement_days: number
          id: string
          is_active: boolean
          is_encashable: boolean
          is_paid: boolean
          name_en: string
          name_ur: string | null
          tenant_id: string
        }
        Insert: {
          accrual_method?: Database["public"]["Enums"]["leave_accrual_method"]
          carry_forward_cap_days?: number | null
          code: string
          doc_required_after_days?: number | null
          effective_from?: string
          eligible_contract_types?: string[]
          eligible_genders?: string[]
          entitlement_days: number
          id?: string
          is_active?: boolean
          is_encashable?: boolean
          is_paid?: boolean
          name_en: string
          name_ur?: string | null
          tenant_id: string
        }
        Update: {
          accrual_method?: Database["public"]["Enums"]["leave_accrual_method"]
          carry_forward_cap_days?: number | null
          code?: string
          doc_required_after_days?: number | null
          effective_from?: string
          eligible_contract_types?: string[]
          eligible_genders?: string[]
          entitlement_days?: number
          id?: string
          is_active?: boolean
          is_encashable?: boolean
          is_paid?: boolean
          name_en?: string
          name_ur?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "leave_type_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      login_attempt: {
        Row: {
          created_at: string
          id: string
          identifier: string
          succeeded: boolean
        }
        Insert: {
          created_at?: string
          id?: string
          identifier: string
          succeeded: boolean
        }
        Update: {
          created_at?: string
          id?: string
          identifier?: string
          succeeded?: boolean
        }
        Relationships: []
      }
      otp_attempt: {
        Row: {
          channel: string
          created_at: string
          id: string
          kind: string
          phone_e164: string
          seq: number
        }
        Insert: {
          channel?: string
          created_at?: string
          id?: string
          kind: string
          phone_e164: string
          seq?: number
        }
        Update: {
          channel?: string
          created_at?: string
          id?: string
          kind?: string
          phone_e164?: string
          seq?: number
        }
        Relationships: []
      }
      permission: {
        Row: {
          code: string
          label: string
          label_ur: string | null
          module: string
        }
        Insert: {
          code: string
          label: string
          label_ur?: string | null
          module: string
        }
        Update: {
          code?: string
          label?: string
          label_ur?: string | null
          module?: string
        }
        Relationships: []
      }
      phi_access_log: {
        Row: {
          accessed_at: string
          accessed_by: string | null
          id: string
          student_id: string
        }
        Insert: {
          accessed_at?: string
          accessed_by?: string | null
          id?: string
          student_id: string
        }
        Update: {
          accessed_at?: string
          accessed_by?: string | null
          id?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "phi_access_log_accessed_by_fkey"
            columns: ["accessed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "phi_access_log_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "phi_access_log_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "phi_access_log_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
        ]
      }
      role: {
        Row: {
          code: string
          created_at: string
          deleted_at: string | null
          id: string
          is_system: boolean
          name: string
          name_ur: string | null
          tenant_id: string | null
        }
        Insert: {
          code: string
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_system?: boolean
          name: string
          name_ur?: string | null
          tenant_id?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_system?: boolean
          name?: string
          name_ur?: string | null
          tenant_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "role_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      role_permission: {
        Row: {
          permission_code: string
          role_id: string
        }
        Insert: {
          permission_code: string
          role_id: string
        }
        Update: {
          permission_code?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "role_permission_permission_code_fkey"
            columns: ["permission_code"]
            isOneToOne: false
            referencedRelation: "permission"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "role_permission_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "role"
            referencedColumns: ["id"]
          },
        ]
      }
      roll_number_change_log: {
        Row: {
          changed_at: string
          changed_by: string | null
          enrolment_id: string
          id: string
          new_roll_no: number
          old_roll_no: number | null
          strategy: string
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          enrolment_id: string
          id?: string
          new_roll_no: number
          old_roll_no?: number | null
          strategy: string
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          enrolment_id?: string
          id?: string
          new_roll_no?: number
          old_roll_no?: number | null
          strategy?: string
        }
        Relationships: [
          {
            foreignKeyName: "roll_number_change_log_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "roll_number_change_log_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "roll_number_change_log_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
        ]
      }
      room: {
        Row: {
          block_label: string | null
          campus_id: string
          capacity: number
          code: string
          created_at: string
          id: string
          inactive_from: string | null
          is_active: boolean
          name: string
          room_type: Database["public"]["Enums"]["room_type_enum"]
          tenant_id: string
        }
        Insert: {
          block_label?: string | null
          campus_id: string
          capacity: number
          code: string
          created_at?: string
          id?: string
          inactive_from?: string | null
          is_active?: boolean
          name: string
          room_type?: Database["public"]["Enums"]["room_type_enum"]
          tenant_id: string
        }
        Update: {
          block_label?: string | null
          campus_id?: string
          capacity?: number
          code?: string
          created_at?: string
          id?: string
          inactive_from?: string | null
          is_active?: boolean
          name?: string
          room_type?: Database["public"]["Enums"]["room_type_enum"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "room_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "room_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      section_class_teacher: {
        Row: {
          campus_id: string
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          section_id: string
          session_id: string
          staff_id: string | null
          tenant_id: string
          validity: unknown
        }
        Insert: {
          campus_id: string
          created_at?: string
          effective_from: string
          effective_to?: string | null
          id?: string
          section_id: string
          session_id: string
          staff_id?: string | null
          tenant_id: string
          validity?: unknown
        }
        Update: {
          campus_id?: string
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          section_id?: string
          session_id?: string
          staff_id?: string | null
          tenant_id?: string
          validity?: unknown
        }
        Relationships: [
          {
            foreignKeyName: "section_class_teacher_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_class_teacher_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "class_section"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_class_teacher_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_section_seat_availability"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "section_class_teacher_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_unallocated_section_subject"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "section_class_teacher_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_class_teacher_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "section_class_teacher_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      section_membership_history: {
        Row: {
          created_at: string
          enrolment_id: string
          from_date: string
          id: string
          moved_by: string | null
          reason: string | null
          section_id: string
          to_date: string | null
        }
        Insert: {
          created_at?: string
          enrolment_id: string
          from_date: string
          id?: string
          moved_by?: string | null
          reason?: string | null
          section_id: string
          to_date?: string | null
        }
        Update: {
          created_at?: string
          enrolment_id?: string
          from_date?: string
          id?: string
          moved_by?: string | null
          reason?: string | null
          section_id?: string
          to_date?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "section_membership_history_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_membership_history_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "section_membership_history_moved_by_fkey"
            columns: ["moved_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "section_membership_history_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "class_section"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_membership_history_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_section_seat_availability"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "section_membership_history_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_unallocated_section_subject"
            referencedColumns: ["section_id"]
          },
        ]
      }
      section_subject_teacher: {
        Row: {
          campus_id: string
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          role: Database["public"]["Enums"]["allocation_role"]
          section_id: string
          session_id: string
          staff_id: string | null
          subject_id: string
          tenant_id: string
          validity: unknown
        }
        Insert: {
          campus_id: string
          created_at?: string
          effective_from: string
          effective_to?: string | null
          id?: string
          role?: Database["public"]["Enums"]["allocation_role"]
          section_id: string
          session_id: string
          staff_id?: string | null
          subject_id: string
          tenant_id: string
          validity?: unknown
        }
        Update: {
          campus_id?: string
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          role?: Database["public"]["Enums"]["allocation_role"]
          section_id?: string
          session_id?: string
          staff_id?: string | null
          subject_id?: string
          tenant_id?: string
          validity?: unknown
        }
        Relationships: [
          {
            foreignKeyName: "section_subject_teacher_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_subject_teacher_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "class_section"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_subject_teacher_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_section_seat_availability"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "section_subject_teacher_section_id_fkey"
            columns: ["section_id"]
            isOneToOne: false
            referencedRelation: "v_unallocated_section_subject"
            referencedColumns: ["section_id"]
          },
          {
            foreignKeyName: "section_subject_teacher_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_subject_teacher_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "section_subject_teacher_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subject"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "section_subject_teacher_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      sibling_discount_scheme_rank: {
        Row: {
          scheme_id: string
          sibling_rank: number
          tenant_id: string
        }
        Insert: {
          scheme_id: string
          sibling_rank: number
          tenant_id: string
        }
        Update: {
          scheme_id?: string
          sibling_rank?: number
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sibling_discount_scheme_rank_scheme_id_fkey"
            columns: ["scheme_id"]
            isOneToOne: false
            referencedRelation: "concession_scheme"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sibling_discount_scheme_rank_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      sibling_group: {
        Row: {
          campus_id: string
          guardian_cnic_norm: string
          id: string
          last_scanned_at: string
          member_enrolment_ids: string[]
          session_id: string
          tenant_id: string
        }
        Insert: {
          campus_id: string
          guardian_cnic_norm: string
          id?: string
          last_scanned_at?: string
          member_enrolment_ids: string[]
          session_id: string
          tenant_id: string
        }
        Update: {
          campus_id?: string
          guardian_cnic_norm?: string
          id?: string
          last_scanned_at?: string
          member_enrolment_ids?: string[]
          session_id?: string
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sibling_group_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sibling_group_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sibling_group_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      staff: {
        Row: {
          campus_id: string
          cnic: string | null
          contract_type: string
          created_at: string
          department_id: string | null
          designation_id: string | null
          dob: string | null
          doj: string
          employee_code: string
          employment_status: Database["public"]["Enums"]["employment_status"]
          employment_status_changed_at: string | null
          full_name: string
          full_name_ur: string | null
          gender: Database["public"]["Enums"]["gender"]
          id: string
          id_document_type: Database["public"]["Enums"]["id_document_type"]
          passport_no: string | null
          tenant_id: string
          user_id: string | null
        }
        Insert: {
          campus_id: string
          cnic?: string | null
          contract_type?: string
          created_at?: string
          department_id?: string | null
          designation_id?: string | null
          dob?: string | null
          doj?: string
          employee_code: string
          employment_status?: Database["public"]["Enums"]["employment_status"]
          employment_status_changed_at?: string | null
          full_name: string
          full_name_ur?: string | null
          gender: Database["public"]["Enums"]["gender"]
          id?: string
          id_document_type?: Database["public"]["Enums"]["id_document_type"]
          passport_no?: string | null
          tenant_id: string
          user_id?: string | null
        }
        Update: {
          campus_id?: string
          cnic?: string | null
          contract_type?: string
          created_at?: string
          department_id?: string | null
          designation_id?: string | null
          dob?: string | null
          doj?: string
          employee_code?: string
          employment_status?: Database["public"]["Enums"]["employment_status"]
          employment_status_changed_at?: string | null
          full_name?: string
          full_name_ur?: string | null
          gender?: Database["public"]["Enums"]["gender"]
          id?: string
          id_document_type?: Database["public"]["Enums"]["id_document_type"]
          passport_no?: string | null
          tenant_id?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "staff_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "department"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_designation_id_fkey"
            columns: ["designation_id"]
            isOneToOne: false
            referencedRelation: "designation"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_attendance: {
        Row: {
          att_date: string
          campus_id: string
          id: string
          marked_at: string
          marked_by: string | null
          remarks: string | null
          source: Database["public"]["Enums"]["attendance_source"]
          staff_id: string
          status: Database["public"]["Enums"]["attendance_status"]
          tenant_id: string
        }
        Insert: {
          att_date: string
          campus_id: string
          id?: string
          marked_at?: string
          marked_by?: string | null
          remarks?: string | null
          source?: Database["public"]["Enums"]["attendance_source"]
          staff_id: string
          status: Database["public"]["Enums"]["attendance_status"]
          tenant_id: string
        }
        Update: {
          att_date?: string
          campus_id?: string
          id?: string
          marked_at?: string
          marked_by?: string | null
          remarks?: string | null
          source?: Database["public"]["Enums"]["attendance_source"]
          staff_id?: string
          status?: Database["public"]["Enums"]["attendance_status"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_attendance_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_attendance_marked_by_fkey"
            columns: ["marked_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "staff_attendance_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_attendance_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_campus: {
        Row: {
          campus_id: string
          staff_id: string
        }
        Insert: {
          campus_id: string
          staff_id: string
        }
        Update: {
          campus_id?: string
          staff_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_campus_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_campus_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_contract: {
        Row: {
          contract_type: Database["public"]["Enums"]["contract_type"]
          contracted_periods_per_week: number | null
          created_at: string
          created_by: string | null
          end_date: string | null
          id: string
          notice_period_days: number | null
          probation_confirmed_at: string | null
          staff_id: string
          start_date: string
          supersedes_id: string | null
          tenant_id: string
        }
        Insert: {
          contract_type: Database["public"]["Enums"]["contract_type"]
          contracted_periods_per_week?: number | null
          created_at?: string
          created_by?: string | null
          end_date?: string | null
          id?: string
          notice_period_days?: number | null
          probation_confirmed_at?: string | null
          staff_id: string
          start_date: string
          supersedes_id?: string | null
          tenant_id: string
        }
        Update: {
          contract_type?: Database["public"]["Enums"]["contract_type"]
          contracted_periods_per_week?: number | null
          created_at?: string
          created_by?: string | null
          end_date?: string | null
          id?: string
          notice_period_days?: number | null
          probation_confirmed_at?: string | null
          staff_id?: string
          start_date?: string
          supersedes_id?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_contract_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "staff_contract_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_contract_supersedes_id_fkey"
            columns: ["supersedes_id"]
            isOneToOne: false
            referencedRelation: "staff_contract"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_contract_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_contract_pay: {
        Row: {
          allowances: Json
          contract_id: string
          gross_salary: number
        }
        Insert: {
          allowances?: Json
          contract_id: string
          gross_salary: number
        }
        Update: {
          allowances?: Json
          contract_id?: string
          gross_salary?: number
        }
        Relationships: [
          {
            foreignKeyName: "staff_contract_pay_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: true
            referencedRelation: "staff_contract"
            referencedColumns: ["id"]
          },
        ]
      }
      stream: {
        Row: {
          applies_from_ordinal: number
          board: Database["public"]["Enums"]["board"]
          code: string
          created_at: string
          id: string
          is_active: boolean
          name_en: string
          name_ur: string | null
          tenant_id: string
        }
        Insert: {
          applies_from_ordinal: number
          board: Database["public"]["Enums"]["board"]
          code: string
          created_at?: string
          id?: string
          is_active?: boolean
          name_en: string
          name_ur?: string | null
          tenant_id: string
        }
        Update: {
          applies_from_ordinal?: number
          board?: Database["public"]["Enums"]["board"]
          code?: string
          created_at?: string
          id?: string
          is_active?: boolean
          name_en?: string
          name_ur?: string | null
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stream_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      student: {
        Row: {
          address: Json
          b_form_no: string | null
          bform_override_reason: string | null
          blood_group: string | null
          campus_id: string
          created_at: string
          dob: string
          family_group_id: string | null
          father_name_en: string | null
          father_name_ur: string | null
          gender: Database["public"]["Enums"]["gender"]
          gr_number: string
          house_id: string | null
          id: string
          name_en: string
          name_ur: string | null
          nationality: string
          no_readmission_flag: boolean
          photo_path: string | null
          religion: string | null
          status: Database["public"]["Enums"]["student_status"]
          tenant_id: string
        }
        Insert: {
          address?: Json
          b_form_no?: string | null
          bform_override_reason?: string | null
          blood_group?: string | null
          campus_id: string
          created_at?: string
          dob: string
          family_group_id?: string | null
          father_name_en?: string | null
          father_name_ur?: string | null
          gender: Database["public"]["Enums"]["gender"]
          gr_number: string
          house_id?: string | null
          id?: string
          name_en: string
          name_ur?: string | null
          nationality?: string
          no_readmission_flag?: boolean
          photo_path?: string | null
          religion?: string | null
          status?: Database["public"]["Enums"]["student_status"]
          tenant_id: string
        }
        Update: {
          address?: Json
          b_form_no?: string | null
          bform_override_reason?: string | null
          blood_group?: string | null
          campus_id?: string
          created_at?: string
          dob?: string
          family_group_id?: string | null
          father_name_en?: string | null
          father_name_ur?: string | null
          gender?: Database["public"]["Enums"]["gender"]
          gr_number?: string
          house_id?: string | null
          id?: string
          name_en?: string
          name_ur?: string | null
          nationality?: string
          no_readmission_flag?: boolean
          photo_path?: string | null
          religion?: string | null
          status?: Database["public"]["Enums"]["student_status"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "student_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_family_group_fk"
            columns: ["family_group_id"]
            isOneToOne: false
            referencedRelation: "family_group"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      student_guardian: {
        Row: {
          created_at: string
          from_date: string
          guardian_id: string
          is_primary: boolean
          may_collect_child: boolean
          priority: number
          receives_academic: boolean
          receives_billing: boolean
          relationship: Database["public"]["Enums"]["guardian_relationship"]
          student_id: string
          tenant_id: string
          to_date: string | null
        }
        Insert: {
          created_at?: string
          from_date?: string
          guardian_id: string
          is_primary?: boolean
          may_collect_child?: boolean
          priority?: number
          receives_academic?: boolean
          receives_billing?: boolean
          relationship: Database["public"]["Enums"]["guardian_relationship"]
          student_id: string
          tenant_id: string
          to_date?: string | null
        }
        Update: {
          created_at?: string
          from_date?: string
          guardian_id?: string
          is_primary?: boolean
          may_collect_child?: boolean
          priority?: number
          receives_academic?: boolean
          receives_billing?: boolean
          relationship?: Database["public"]["Enums"]["guardian_relationship"]
          student_id?: string
          tenant_id?: string
          to_date?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_guardian_guardian_id_fkey"
            columns: ["guardian_id"]
            isOneToOne: false
            referencedRelation: "guardian"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_guardian_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_guardian_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_guardian_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_guardian_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      student_medical: {
        Row: {
          accommodations: Json
          allergies: string[]
          campus_id: string
          conditions: string[]
          disability_type: Database["public"]["Enums"]["disability_type"]
          emergency_contact_name: string | null
          emergency_contact_phone: string | null
          has_critical_allergy: boolean
          medications: string[]
          student_id: string
          tenant_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          accommodations?: Json
          allergies?: string[]
          campus_id: string
          conditions?: string[]
          disability_type?: Database["public"]["Enums"]["disability_type"]
          emergency_contact_name?: string | null
          emergency_contact_phone?: string | null
          has_critical_allergy?: boolean
          medications?: string[]
          student_id: string
          tenant_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          accommodations?: Json
          allergies?: string[]
          campus_id?: string
          conditions?: string[]
          disability_type?: Database["public"]["Enums"]["disability_type"]
          emergency_contact_name?: string | null
          emergency_contact_phone?: string | null
          has_critical_allergy?: boolean
          medications?: string[]
          student_id?: string
          tenant_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_medical_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_medical_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: true
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_medical_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: true
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_medical_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: true
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_medical_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_medical_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      student_status_history: {
        Row: {
          changed_at: string
          changed_by: string | null
          effective_date: string
          from_status: Database["public"]["Enums"]["student_status"]
          id: string
          reason_code: Database["public"]["Enums"]["status_reason_code"]
          reason_note: string | null
          student_id: string
          to_status: Database["public"]["Enums"]["student_status"]
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          effective_date: string
          from_status: Database["public"]["Enums"]["student_status"]
          id?: string
          reason_code: Database["public"]["Enums"]["status_reason_code"]
          reason_note?: string | null
          student_id: string
          to_status: Database["public"]["Enums"]["student_status"]
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          effective_date?: string
          from_status?: Database["public"]["Enums"]["student_status"]
          id?: string
          reason_code?: Database["public"]["Enums"]["status_reason_code"]
          reason_note?: string | null
          student_id?: string
          to_status?: Database["public"]["Enums"]["student_status"]
        }
        Relationships: [
          {
            foreignKeyName: "student_status_history_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "student_status_history_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_status_history_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_status_history_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
        ]
      }
      student_status_transition: {
        Row: {
          from_status: Database["public"]["Enums"]["student_status"]
          requires_document: boolean
          requires_reason_code:
            | Database["public"]["Enums"]["status_reason_code"]
            | null
          requires_role: Database["public"]["Enums"]["app_role"] | null
          to_status: Database["public"]["Enums"]["student_status"]
        }
        Insert: {
          from_status: Database["public"]["Enums"]["student_status"]
          requires_document?: boolean
          requires_reason_code?:
            | Database["public"]["Enums"]["status_reason_code"]
            | null
          requires_role?: Database["public"]["Enums"]["app_role"] | null
          to_status: Database["public"]["Enums"]["student_status"]
        }
        Update: {
          from_status?: Database["public"]["Enums"]["student_status"]
          requires_document?: boolean
          requires_reason_code?:
            | Database["public"]["Enums"]["status_reason_code"]
            | null
          requires_role?: Database["public"]["Enums"]["app_role"] | null
          to_status?: Database["public"]["Enums"]["student_status"]
        }
        Relationships: []
      }
      student_transport: {
        Row: {
          campus_id: string
          created_at: string
          direction: Database["public"]["Enums"]["transport_direction"]
          fee_slab_id: string | null
          from_date: string
          id: string
          opt_in: boolean
          pickup_area: string | null
          route_id: string | null
          session_id: string
          stop_id: string | null
          student_id: string
          tenant_id: string
          to_date: string | null
        }
        Insert: {
          campus_id: string
          created_at?: string
          direction?: Database["public"]["Enums"]["transport_direction"]
          fee_slab_id?: string | null
          from_date?: string
          id?: string
          opt_in?: boolean
          pickup_area?: string | null
          route_id?: string | null
          session_id: string
          stop_id?: string | null
          student_id: string
          tenant_id: string
          to_date?: string | null
        }
        Update: {
          campus_id?: string
          created_at?: string
          direction?: Database["public"]["Enums"]["transport_direction"]
          fee_slab_id?: string | null
          from_date?: string
          id?: string
          opt_in?: boolean
          pickup_area?: string | null
          route_id?: string | null
          session_id?: string
          stop_id?: string | null
          student_id?: string
          tenant_id?: string
          to_date?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_transport_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_transport_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_transport_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_transport_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_transport_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_transport_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      subject: {
        Row: {
          alternate_of_subject_id: string | null
          code: string
          created_at: string
          default_max_marks: number | null
          id: string
          is_active: boolean
          is_examinable: boolean
          name_en: string
          name_ur: string
          subject_type: Database["public"]["Enums"]["subject_type"]
          tenant_id: string
        }
        Insert: {
          alternate_of_subject_id?: string | null
          code: string
          created_at?: string
          default_max_marks?: number | null
          id?: string
          is_active?: boolean
          is_examinable?: boolean
          name_en: string
          name_ur: string
          subject_type?: Database["public"]["Enums"]["subject_type"]
          tenant_id: string
        }
        Update: {
          alternate_of_subject_id?: string | null
          code?: string
          created_at?: string
          default_max_marks?: number | null
          id?: string
          is_active?: boolean
          is_examinable?: boolean
          name_en?: string
          name_ur?: string
          subject_type?: Database["public"]["Enums"]["subject_type"]
          tenant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "subject_alternate_of_subject_id_fkey"
            columns: ["alternate_of_subject_id"]
            isOneToOne: false
            referencedRelation: "subject"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subject_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      subject_board_code: {
        Row: {
          board: Database["public"]["Enums"]["board"]
          board_code: string
          subject_id: string
        }
        Insert: {
          board: Database["public"]["Enums"]["board"]
          board_code: string
          subject_id: string
        }
        Update: {
          board?: Database["public"]["Enums"]["board"]
          board_code?: string
          subject_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "subject_board_code_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subject"
            referencedColumns: ["id"]
          },
        ]
      }
      teacher_subject_competency: {
        Row: {
          created_at: string
          document_path: string | null
          id: string
          max_class_ordinal: number
          min_class_ordinal: number
          source: Database["public"]["Enums"]["competency_source_enum"]
          staff_id: string
          subject_id: string
          tenant_id: string
          verified_at: string | null
          verified_by: string | null
        }
        Insert: {
          created_at?: string
          document_path?: string | null
          id?: string
          max_class_ordinal: number
          min_class_ordinal: number
          source?: Database["public"]["Enums"]["competency_source_enum"]
          staff_id: string
          subject_id: string
          tenant_id: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Update: {
          created_at?: string
          document_path?: string | null
          id?: string
          max_class_ordinal?: number
          min_class_ordinal?: number
          source?: Database["public"]["Enums"]["competency_source_enum"]
          staff_id?: string
          subject_id?: string
          tenant_id?: string
          verified_at?: string | null
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "teacher_subject_competency_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "teacher_subject_competency_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subject"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "teacher_subject_competency_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "teacher_subject_competency_verified_by_fkey"
            columns: ["verified_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      tenant: {
        Row: {
          country_code: string
          created_at: string
          currency: string
          deleted_at: string | null
          id: string
          legal_name: string | null
          locale: string
          name: string
          name_ur: string | null
          settings: Json
          slug: string
          status: Database["public"]["Enums"]["tenant_status"]
          timezone: string
        }
        Insert: {
          country_code?: string
          created_at?: string
          currency?: string
          deleted_at?: string | null
          id?: string
          legal_name?: string | null
          locale?: string
          name: string
          name_ur?: string | null
          settings?: Json
          slug: string
          status?: Database["public"]["Enums"]["tenant_status"]
          timezone?: string
        }
        Update: {
          country_code?: string
          created_at?: string
          currency?: string
          deleted_at?: string | null
          id?: string
          legal_name?: string | null
          locale?: string
          name?: string
          name_ur?: string | null
          settings?: Json
          slug?: string
          status?: Database["public"]["Enums"]["tenant_status"]
          timezone?: string
        }
        Relationships: []
      }
      tenant_invitation: {
        Row: {
          accepted_at: string | null
          accepted_user_id: string | null
          app_role: Database["public"]["Enums"]["app_role"]
          campus_ids: string[]
          created_at: string
          email: string
          expires_at: string
          id: string
          invited_by: string | null
          tenant_id: string
          token: string
        }
        Insert: {
          accepted_at?: string | null
          accepted_user_id?: string | null
          app_role: Database["public"]["Enums"]["app_role"]
          campus_ids?: string[]
          created_at?: string
          email: string
          expires_at?: string
          id?: string
          invited_by?: string | null
          tenant_id: string
          token?: string
        }
        Update: {
          accepted_at?: string | null
          accepted_user_id?: string | null
          app_role?: Database["public"]["Enums"]["app_role"]
          campus_ids?: string[]
          created_at?: string
          email?: string
          expires_at?: string
          id?: string
          invited_by?: string | null
          tenant_id?: string
          token?: string
        }
        Relationships: [
          {
            foreignKeyName: "tenant_invitation_accepted_user_id_fkey"
            columns: ["accepted_user_id"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "tenant_invitation_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "tenant_invitation_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      tenant_setting: {
        Row: {
          created_at: string
          key: string
          tenant_id: string
          value: Json
        }
        Insert: {
          created_at?: string
          key: string
          tenant_id: string
          value: Json
        }
        Update: {
          created_at?: string
          key?: string
          tenant_id?: string
          value?: Json
        }
        Relationships: [
          {
            foreignKeyName: "tenant_setting_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      user_campus: {
        Row: {
          campus_id: string
          is_active: boolean
          tenant_id: string
          user_id: string
        }
        Insert: {
          campus_id: string
          is_active?: boolean
          tenant_id: string
          user_id: string
        }
        Update: {
          campus_id?: string
          is_active?: boolean
          tenant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_campus_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_campus_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "app_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
    }
    Views: {
      v_class_weekly_period_load: {
        Row: {
          campus_id: string | null
          class_level_id: string | null
          session_id: string | null
          stream_id: string | null
          tenant_id: string | null
          total_weekly_periods: number | null
        }
        Relationships: [
          {
            foreignKeyName: "class_subject_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_stream_id_fkey"
            columns: ["stream_id"]
            isOneToOne: false
            referencedRelation: "stream"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      v_daily_collection: {
        Row: {
          amount_paisa: number | null
          campus_id: string | null
          enrolment_id: string | null
          ledger_id: string | null
          mode: Database["public"]["Enums"]["fee_payment_mode"] | null
          payment_id: string | null
          tenant_id: string | null
          value_date: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fee_ledger_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "enrolment"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fee_ledger_enrolment_id_fkey"
            columns: ["enrolment_id"]
            isOneToOne: false
            referencedRelation: "v_student_outstanding"
            referencedColumns: ["enrolment_id"]
          },
          {
            foreignKeyName: "fee_ledger_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      v_guardian_children: {
        Row: {
          campus_id: string | null
          gr_number: string | null
          guardian_id: string | null
          name_en: string | null
          student_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_guardian_guardian_id_fkey"
            columns: ["guardian_id"]
            isOneToOne: false
            referencedRelation: "guardian"
            referencedColumns: ["id"]
          },
        ]
      }
      v_section_seat_availability: {
        Row: {
          active_count: number | null
          campus_id: string | null
          capacity: number | null
          class_level_id: string | null
          name: string | null
          seats_free: number | null
          section_id: string | null
          session_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "class_section_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_section_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_section_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
        ]
      }
      v_sibling_rank: {
        Row: {
          family_group_id: string | null
          sibling_rank: number | null
          student_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_family_group_fk"
            columns: ["family_group_id"]
            isOneToOne: false
            referencedRelation: "family_group"
            referencedColumns: ["id"]
          },
        ]
      }
      v_student_outstanding: {
        Row: {
          campus_id: string | null
          enrolment_id: string | null
          outstanding_paisa: number | null
          session_id: string | null
          student_id: string | null
          tenant_id: string | null
        }
        Insert: {
          campus_id?: string | null
          enrolment_id?: string | null
          outstanding_paisa?: never
          session_id?: string | null
          student_id?: string | null
          tenant_id?: string | null
        }
        Update: {
          campus_id?: string | null
          enrolment_id?: string | null
          outstanding_paisa?: never
          session_id?: string | null
          student_id?: string | null
          tenant_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "enrolment_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "enrolment_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "enrolment_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "enrolment_tenant_id_fkey"
            columns: ["tenant_id"]
            isOneToOne: false
            referencedRelation: "tenant"
            referencedColumns: ["id"]
          },
        ]
      }
      v_unallocated_section_subject: {
        Row: {
          campus_id: string | null
          class_level_id: string | null
          class_subject_id: string | null
          section_id: string | null
          section_name: string | null
          session_id: string | null
          subject_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "class_subject_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_class_level_id_fkey"
            columns: ["class_level_id"]
            isOneToOne: false
            referencedRelation: "class_level"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "class_subject_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subject"
            referencedColumns: ["id"]
          },
        ]
      }
      v_unrouted_transport: {
        Row: {
          campus_id: string | null
          direction: Database["public"]["Enums"]["transport_direction"] | null
          id: string | null
          name_en: string | null
          pickup_area: string | null
          session_id: string | null
          student_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_transport_campus_id_fkey"
            columns: ["campus_id"]
            isOneToOne: false
            referencedRelation: "campus"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_transport_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "academic_session"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_transport_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "student"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_transport_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_guardian_children"
            referencedColumns: ["student_id"]
          },
          {
            foreignKeyName: "student_transport_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "v_sibling_rank"
            referencedColumns: ["student_id"]
          },
        ]
      }
    }
    Functions: {
      accept_invitation: { Args: { p_token: string }; Returns: string }
      add_holiday: {
        Args: { p_campus_id?: string; p_holiday_date: string; p_name: string }
        Returns: string
      }
      add_structure_line: {
        Args: {
          p_amount_paisa: number
          p_billing_month_mask?: number
          p_class_id: string
          p_fee_head_id: string
          p_frequency: Database["public"]["Enums"]["fee_frequency"]
          p_group_code?: string
          p_structure_id: string
        }
        Returns: string
      }
      advance_leave_approval: {
        Args: {
          p_application_id: string
          p_comment?: string
          p_decision: Database["public"]["Enums"]["approval_decision"]
        }
        Returns: undefined
      }
      allocate_payment: { Args: { p_payment_id: string }; Returns: Json }
      amount_in_words: { Args: { p_amount_paisa: number }; Returns: string }
      apply_advance_credit: {
        Args: { p_challan_id: string; p_enrolment_id: string }
        Returns: number
      }
      apply_for_leave: {
        Args: {
          p_from_date: string
          p_is_half_day?: boolean
          p_leave_type_id: string
          p_reason?: string
          p_staff_id: string
          p_to_date: string
        }
        Returns: string
      }
      apply_late_fees: { Args: { p_run_date?: string }; Returns: Json }
      archive_campus: { Args: { p_campus_id: string }; Returns: undefined }
      assign_class_teacher: {
        Args: {
          p_effective_from: string
          p_section_id: string
          p_staff_id: string
        }
        Returns: Json
      }
      assign_subject_teacher: {
        Args: {
          p_effective_from: string
          p_role?: Database["public"]["Enums"]["allocation_role"]
          p_section_id: string
          p_staff_id: string
          p_subject_id: string
        }
        Returns: Json
      }
      attach_staff_campus: {
        Args: { p_campus_id: string; p_staff_id: string }
        Returns: undefined
      }
      available_seats: {
        Args: {
          p_campus_id: string
          p_class_level_id: string
          p_session_id: string
        }
        Returns: number
      }
      build_challan_render_payload: {
        Args: { p_challan_id: string }
        Returns: Json
      }
      build_collection_report_payload: {
        Args: { p_campus_id: string; p_from: string; p_to: string }
        Returns: Json
      }
      build_fee_plan: { Args: { p_enrolment_id: string }; Returns: string }
      challan_check_digit: { Args: { p_digits: string }; Returns: number }
      check_room_capacity: {
        Args: { p_room_id: string; p_section_id: string }
        Returns: Json
      }
      clone_academic_structure: {
        Args: {
          p_campus_id: string
          p_dry_run?: boolean
          p_from_session_id: string
          p_to_session_id: string
        }
        Returns: Json
      }
      collect_cash_payment: {
        Args: {
          p_amount_paisa: number
          p_challan_id: string
          p_client_idempotency_key: string
          p_mode?: Database["public"]["Enums"]["fee_payment_mode"]
          p_reference_no?: string
        }
        Returns: Json
      }
      compute_late_fee: {
        Args: { p_as_of?: string; p_challan_id: string }
        Returns: number
      }
      confirm_family_group: { Args: { p_group_id: string }; Returns: undefined }
      confirm_probation: { Args: { p_contract_id: string }; Returns: undefined }
      copy_class_subject_map: {
        Args: {
          p_campus_id: string
          p_from_class_level_id: string
          p_session_id: string
          p_to_class_level_id: string
        }
        Returns: Json
      }
      create_academic_session: {
        Args: {
          p_campus_id: string
          p_ends_on: string
          p_name: string
          p_starts_on: string
        }
        Returns: string
      }
      create_audit_partition: { Args: { p_month?: string }; Returns: undefined }
      create_campus: {
        Args: { p_city?: string; p_code: string; p_name: string }
        Returns: string
      }
      create_class_level: {
        Args: {
          p_board_stage?: string
          p_code: string
          p_name_en: string
          p_name_ur: string
          p_ordinal: number
        }
        Returns: string
      }
      create_concession_scheme: {
        Args: {
          p_applicable_head_ids: string[]
          p_approver_role?: Database["public"]["Enums"]["app_role"]
          p_calc_type: Database["public"]["Enums"]["concession_calc_type"]
          p_category?: string
          p_code: string
          p_default_validity_months?: number
          p_max_value?: number
          p_name_en: string
          p_name_ur: string
          p_requires_document?: boolean
          p_value: number
        }
        Returns: string
      }
      create_draft_structure: {
        Args: { p_campus_id: string; p_session_id: string }
        Returns: string
      }
      create_enquiry: {
        Args: {
          p_age_override_reason?: string
          p_campus_id: string
          p_child_name: string
          p_child_name_ur?: string
          p_class_applied_id: string
          p_dob: string
          p_parent_cnic?: string
          p_parent_name: string
          p_phone: string
          p_referrer_name?: string
          p_session_id: string
          p_source: Database["public"]["Enums"]["enquiry_source"]
          p_whatsapp_opt_in: boolean
        }
        Returns: string
      }
      create_fee_head: {
        Args: {
          p_carry_forward_on_arrears?: boolean
          p_code: string
          p_default_frequency?: Database["public"]["Enums"]["fee_frequency"]
          p_gl_code?: string
          p_is_mandatory?: boolean
          p_is_refundable?: boolean
          p_name_en: string
          p_name_ur: string
        }
        Returns: string
      }
      create_followup: {
        Args: {
          p_assigned_to?: string
          p_channel: Database["public"]["Enums"]["followup_channel"]
          p_due_at: string
          p_enquiry_id: string
        }
        Returns: string
      }
      create_late_fee_rule: {
        Args: {
          p_amount_paisa?: number
          p_applicable_head_ids?: string[]
          p_basis: Database["public"]["Enums"]["late_fee_basis"]
          p_campus_id: string
          p_cap_paisa?: number
          p_effective_from?: string
          p_exempt_concession_categories?: string[]
          p_grace_days?: number
          p_max_days?: number
          p_percentage?: number
          p_session_id: string
        }
        Returns: string
      }
      create_leave_type: {
        Args: {
          p_accrual_method?: Database["public"]["Enums"]["leave_accrual_method"]
          p_carry_forward_cap_days?: number
          p_code: string
          p_doc_required_after_days?: number
          p_effective_from?: string
          p_eligible_contract_types?: string[]
          p_eligible_genders?: string[]
          p_entitlement_days: number
          p_is_encashable?: boolean
          p_is_paid?: boolean
          p_name_en: string
          p_name_ur?: string
        }
        Returns: string
      }
      create_next_structure_version: {
        Args: { p_effective_from: string; p_prior_structure_id: string }
        Returns: string
      }
      create_room: {
        Args: {
          p_block_label?: string
          p_campus_id: string
          p_capacity: number
          p_code: string
          p_name: string
          p_room_type: Database["public"]["Enums"]["room_type_enum"]
        }
        Returns: string
      }
      create_section: {
        Args: {
          p_campus_id: string
          p_capacity: number
          p_class_level_id: string
          p_gender_restriction?: Database["public"]["Enums"]["gender"]
          p_medium?: Database["public"]["Enums"]["section_medium"]
          p_name: string
          p_session_id: string
          p_shift?: Database["public"]["Enums"]["section_shift"]
        }
        Returns: string
      }
      create_staff: {
        Args: {
          p_campus_id: string
          p_cnic?: string
          p_contract_type?: string
          p_department_id?: string
          p_designation_id?: string
          p_dob?: string
          p_doj?: string
          p_full_name: string
          p_full_name_ur?: string
          p_gender: Database["public"]["Enums"]["gender"]
          p_id_document_type?: Database["public"]["Enums"]["id_document_type"]
          p_passport_no?: string
        }
        Returns: string
      }
      create_staff_contract: {
        Args: {
          p_allowances?: Json
          p_contract_type: Database["public"]["Enums"]["contract_type"]
          p_contracted_periods_per_week?: number
          p_gross_salary?: number
          p_notice_period_days?: number
          p_staff_id: string
          p_start_date: string
        }
        Returns: string
      }
      create_stream: {
        Args: {
          p_applies_from_ordinal: number
          p_board: Database["public"]["Enums"]["board"]
          p_code: string
          p_name_en: string
          p_name_ur: string
        }
        Returns: string
      }
      create_student: {
        Args: {
          p_b_form_no?: string
          p_bform_override_reason?: string
          p_blood_group?: string
          p_campus_id: string
          p_dob: string
          p_father_name_en?: string
          p_father_name_ur?: string
          p_gender: Database["public"]["Enums"]["gender"]
          p_name_en: string
          p_name_ur?: string
          p_nationality?: string
          p_religion?: string
        }
        Returns: string
      }
      create_subject: {
        Args: {
          p_alternate_of_subject_id?: string
          p_code: string
          p_default_max_marks?: number
          p_is_examinable?: boolean
          p_name_en: string
          p_name_ur: string
          p_subject_type?: Database["public"]["Enums"]["subject_type"]
        }
        Returns: string
      }
      current_contract: {
        Args: { p_on?: string; p_staff_id: string }
        Returns: {
          contract_type: Database["public"]["Enums"]["contract_type"]
          contracted_periods_per_week: number | null
          created_at: string
          created_by: string | null
          end_date: string | null
          id: string
          notice_period_days: number | null
          probation_confirmed_at: string | null
          staff_id: string
          start_date: string
          supersedes_id: string | null
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "staff_contract"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      custom_access_token_hook: { Args: { event: Json }; Returns: Json }
      daily_collection_report: {
        Args: { p_campus_id: string; p_from: string; p_to: string }
        Returns: {
          amount_paisa: number
          mode: Database["public"]["Enums"]["fee_payment_mode"]
          payment_count: number
          value_date: string
        }[]
      }
      decide_concession_award: {
        Args: {
          p_approve: boolean
          p_award_id: string
          p_rejection_reason?: string
        }
        Returns: undefined
      }
      decide_fee_plan_override: {
        Args: { p_approve: boolean; p_line_id: string }
        Returns: undefined
      }
      declare_competency: {
        Args: {
          p_max_class_ordinal: number
          p_min_class_ordinal: number
          p_staff_id: string
          p_subject_id: string
        }
        Returns: string
      }
      delete_class_level: { Args: { p_id: string }; Returns: undefined }
      delete_stream: { Args: { p_id: string }; Returns: undefined }
      detect_sibling_groups: {
        Args: { p_campus_id: string; p_session_id: string }
        Returns: Json
      }
      edit_concession_award: {
        Args: { p_award_id: string; p_new_value: number }
        Returns: undefined
      }
      eligible_leave_types: {
        Args: { p_staff_id: string }
        Returns: {
          accrual_method: Database["public"]["Enums"]["leave_accrual_method"]
          carry_forward_cap_days: number | null
          code: string
          doc_required_after_days: number | null
          effective_from: string
          eligible_contract_types: string[]
          eligible_genders: string[]
          entitlement_days: number
          id: string
          is_active: boolean
          is_encashable: boolean
          is_paid: boolean
          name_en: string
          name_ur: string | null
          tenant_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "leave_type"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      enrol_student: {
        Args: {
          p_override_reason?: string
          p_section_id: string
          p_student_id: string
        }
        Returns: string
      }
      expire_due_concessions: { Args: { p_as_of?: string }; Returns: number }
      finalise_cash_book_day: {
        Args: { p_book_date: string; p_campus_id: string }
        Returns: {
          book_date: string
          campus_id: string
          closing_paisa: number
          disbursements_paisa: number
          finalised_at: string
          finalised_by: string | null
          opening_paisa: number
          receipts_paisa: number
          tenant_id: string
        }
        SetofOptions: {
          from: "*"
          to: "cash_book_day"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      fn_assign_next_roll_no: {
        Args: { p_enrolment_id: string }
        Returns: number
      }
      fn_assign_section: {
        Args: {
          p_enrolment_id: string
          p_from_date?: string
          p_reason?: string
          p_section_id: string
        }
        Returns: undefined
      }
      fn_auto_balance_sections: {
        Args: {
          p_class_level_id: string
          p_session_id: string
          p_student_ids: string[]
        }
        Returns: Json
      }
      fn_change_student_status: {
        Args: {
          p_effective_date?: string
          p_reason_code: Database["public"]["Enums"]["status_reason_code"]
          p_reason_note?: string
          p_student_id: string
          p_to_status: Database["public"]["Enums"]["student_status"]
          p_waive_document?: boolean
        }
        Returns: undefined
      }
      fn_close_enquiry: {
        Args: {
          p_enquiry_id: string
          p_status: Database["public"]["Enums"]["enquiry_status"]
        }
        Returns: undefined
      }
      fn_complete_followup: {
        Args: {
          p_followup_id: string
          p_outcome: Database["public"]["Enums"]["followup_outcome"]
          p_outcome_note?: string
        }
        Returns: undefined
      }
      fn_decide_leave_application: {
        Args: {
          p_application_id: string
          p_comment?: string
          p_decision: Database["public"]["Enums"]["leave_application_status"]
        }
        Returns: undefined
      }
      fn_dismiss_duplicate_enquiry: {
        Args: { p_enquiry_a: string; p_enquiry_b: string }
        Returns: undefined
      }
      fn_escalate_overdue_steps: { Args: never; Returns: number }
      fn_expire_offers: { Args: never; Returns: number }
      fn_extend_offer: {
        Args: { p_new_expires_at: string; p_offer_id: string; p_reason: string }
        Returns: undefined
      }
      fn_find_duplicate_enquiries: {
        Args: {
          p_cnic?: string
          p_dob?: string
          p_exclude_enquiry_id?: string
          p_name?: string
          p_phone?: string
        }
        Returns: {
          campus_id: string
          child_name: string
          enquiry_no: string
          id: string
          last_followup_at: string
          phone_e164: string
          status: Database["public"]["Enums"]["enquiry_status"]
        }[]
      }
      fn_find_guardian_by_cnic: { Args: { p_cnic: string }; Returns: string }
      fn_find_or_create_guardian: {
        Args: {
          p_alt_phone?: string
          p_cnic?: string
          p_email?: string
          p_name_en: string
          p_name_ur?: string
          p_occupation?: string
          p_phone_e164?: string
        }
        Returns: string
      }
      fn_find_overdue_leave_students: {
        Args: never
        Returns: {
          days_on_leave: number
          student_id: string
        }[]
      }
      fn_find_readmission_candidates: {
        Args: { p_b_form_no?: string; p_dob?: string; p_name_en?: string }
        Returns: {
          gr_number: string
          name_en: string
          no_readmission_flag: boolean
          status: Database["public"]["Enums"]["student_status"]
          student_id: string
        }[]
      }
      fn_flag_probation_lapsed: {
        Args: never
        Returns: {
          contract_type: Database["public"]["Enums"]["contract_type"]
          contracted_periods_per_week: number | null
          created_at: string
          created_by: string | null
          end_date: string | null
          id: string
          notice_period_days: number | null
          probation_confirmed_at: string | null
          staff_id: string
          start_date: string
          supersedes_id: string | null
          tenant_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "staff_contract"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      fn_get_student_medical: {
        Args: { p_student_id: string }
        Returns: {
          accommodations: Json
          allergies: string[]
          campus_id: string
          conditions: string[]
          disability_type: Database["public"]["Enums"]["disability_type"]
          emergency_contact_name: string | null
          emergency_contact_phone: string | null
          has_critical_allergy: boolean
          medications: string[]
          student_id: string
          tenant_id: string
          updated_at: string
          updated_by: string | null
        }
        SetofOptions: {
          from: "*"
          to: "student_medical"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      fn_grant_leave_balance: {
        Args: {
          p_days: number
          p_entry_type?: Database["public"]["Enums"]["leave_ledger_entry_type"]
          p_leave_type_id: string
          p_staff_id: string
        }
        Returns: undefined
      }
      fn_issue_offer: {
        Args: {
          p_admission_fee_amount: number
          p_application_id: string
          p_valid_days?: number
        }
        Returns: string
      }
      fn_leave_balance: {
        Args: { p_leave_type_id: string; p_staff_id: string }
        Returns: number
      }
      fn_merge_enquiry: {
        Args: { p_loser_id: string; p_survivor_id: string }
        Returns: undefined
      }
      fn_merge_family_groups: {
        Args: { p_keep_id: string; p_merge_id: string }
        Returns: undefined
      }
      fn_next_enquiry_no: {
        Args: { p_campus_id: string; p_session_id: string }
        Returns: string
      }
      fn_readmit_student: {
        Args: {
          p_override_reason?: string
          p_section_id: string
          p_student_id: string
        }
        Returns: string
      }
      fn_reassign_followups: {
        Args: { p_from_user: string; p_to_user: string }
        Returns: number
      }
      fn_reinstate_offer: { Args: { p_offer_id: string }; Returns: undefined }
      fn_resequence_roll_numbers: {
        Args: {
          p_section_id: string
          p_session_id: string
          p_strategy?: string
        }
        Returns: number
      }
      fn_respond_to_offer: {
        Args: {
          p_decline_reason?: Database["public"]["Enums"]["offer_decline_reason"]
          p_offer_id: string
          p_response: Database["public"]["Enums"]["offer_status"]
        }
        Returns: undefined
      }
      fn_set_roll_no: {
        Args: { p_enrolment_id: string; p_roll_no: number }
        Returns: undefined
      }
      fn_set_transport_optin: {
        Args: {
          p_direction?: Database["public"]["Enums"]["transport_direction"]
          p_opt_in: boolean
          p_pickup_area?: string
          p_session_id: string
          p_student_id: string
        }
        Returns: string
      }
      fn_student_medical_flags: {
        Args: { p_campus_id?: string }
        Returns: {
          has_critical_allergy: boolean
          student_id: string
        }[]
      }
      fn_submit_application: {
        Args: {
          p_enquiry_id: string
          p_group_applied?: Database["public"]["Enums"]["academic_group"]
          p_prev_class_passed?: string
          p_prev_school?: string
        }
        Returns: string
      }
      fn_suggest_family_group: {
        Args: { p_cnic: string }
        Returns: {
          gr_number: string
          name_en: string
          student_id: string
        }[]
      }
      fn_upsert_student_medical: {
        Args: {
          p_accommodations?: Json
          p_allergies?: string[]
          p_conditions?: string[]
          p_disability_type?: Database["public"]["Enums"]["disability_type"]
          p_emergency_contact_name?: string
          p_emergency_contact_phone?: string
          p_has_critical_allergy?: boolean
          p_medications?: string[]
          p_student_id: string
        }
        Returns: undefined
      }
      generate_challans: {
        Args: {
          p_campus_id: string
          p_dry_run?: boolean
          p_period: string
          p_session_id: string
        }
        Returns: Json
      }
      get_invitation_preview: {
        Args: { p_token: string }
        Returns: {
          app_role: Database["public"]["Enums"]["app_role"]
          email: string
          tenant_name: string
          valid: boolean
        }[]
      }
      invite_user: {
        Args: {
          p_campus_ids?: string[]
          p_email: string
          p_role: Database["public"]["Enums"]["app_role"]
        }
        Returns: string
      }
      is_login_locked: { Args: { p_identifier: string }; Returns: boolean }
      is_otp_locked: { Args: { p_phone: string }; Returns: boolean }
      issue_otp: { Args: { p_phone: string }; Returns: Json }
      link_enrolment_promotion: {
        Args: { p_new_enrolment_id: string; p_old_enrolment_id: string }
        Returns: undefined
      }
      link_family_group: {
        Args: { p_father_cnic?: string; p_student_ids: string[] }
        Returns: string
      }
      link_guardian: {
        Args: {
          p_guardian_id: string
          p_is_primary?: boolean
          p_may_collect_child?: boolean
          p_receives_academic?: boolean
          p_receives_billing?: boolean
          p_relationship: Database["public"]["Enums"]["guardian_relationship"]
          p_student_id: string
        }
        Returns: undefined
      }
      link_staff_user_account: {
        Args: { p_staff_id: string; p_user_id: string }
        Returns: undefined
      }
      lookup_challan_for_counter: {
        Args: { p_challan_no: string }
        Returns: Json
      }
      mark_staff_attendance_bulk: {
        Args: { p_campus_id: string; p_date: string; p_rows: Json }
        Returns: Json
      }
      my_overdue_followups: {
        Args: never
        Returns: {
          assigned_to: string | null
          campus_id: string
          channel: Database["public"]["Enums"]["followup_channel"]
          completed_at: string | null
          completed_by: string | null
          created_at: string
          created_by: string | null
          due_at: string
          enquiry_id: string
          id: string
          outcome: Database["public"]["Enums"]["followup_outcome"] | null
          outcome_note: string | null
          tenant_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "admission_followup"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      next_challan_no: {
        Args: { p_campus_id: string; p_session_id: string; p_tenant_id: string }
        Returns: string
      }
      normalize_pk_phone: { Args: { p_phone: string }; Returns: string }
      outstanding_balance_as_of: {
        Args: { p_as_of?: string; p_enrolment_id: string }
        Returns: number
      }
      post_ledger_entry: {
        Args: {
          p_amount_paisa: number
          p_direction: Database["public"]["Enums"]["fee_ledger_direction"]
          p_enrolment_id: string
          p_entry_type: Database["public"]["Enums"]["fee_ledger_entry_type"]
          p_fee_head_id?: string
          p_source_id?: string
          p_source_type?: string
          p_value_date?: string
        }
        Returns: string
      }
      print_receipt: { Args: { p_receipt_id: string }; Returns: Json }
      propose_fee_plan_override: {
        Args: {
          p_line_id: string
          p_new_amount_paisa: number
          p_reason: string
        }
        Returns: undefined
      }
      provision_tenant: {
        Args: { p_legal_name: string; p_owner_email: string; p_slug: string }
        Returns: string
      }
      publish_fee_structure: {
        Args: { p_regulator_reference?: string; p_structure_id: string }
        Returns: undefined
      }
      record_payment: {
        Args: {
          p_amount_paisa: number
          p_enrolment_id: string
          p_mode: Database["public"]["Enums"]["fee_payment_mode"]
          p_reference_no?: string
          p_value_date?: string
        }
        Returns: string
      }
      register_login_attempt: {
        Args: { p_identifier: string; p_succeeded: boolean }
        Returns: undefined
      }
      register_otp_attempt: {
        Args: { p_kind: string; p_phone: string }
        Returns: undefined
      }
      remove_fee_plan_line: {
        Args: { p_line_id: string; p_reason?: string }
        Returns: undefined
      }
      request_concession_award: {
        Args: {
          p_document_paths?: string[]
          p_effective_from: string
          p_effective_to: string
          p_enrolment_id: string
          p_scheme_id: string
          p_value: number
        }
        Returns: string
      }
      resolve_fee_structure: {
        Args: {
          p_campus_id: string
          p_period_start: string
          p_session_id: string
        }
        Returns: string
      }
      reverse_ledger_entry: {
        Args: { p_ledger_id: string; p_reason: string }
        Returns: string
      }
      seed_default_class_levels: {
        Args: { p_tenant_id: string }
        Returns: undefined
      }
      seed_default_fee_heads: {
        Args: { p_tenant_id: string }
        Returns: undefined
      }
      seed_tenant_roles: { Args: { p_tenant_id: string }; Returns: undefined }
      set_academic_terms: {
        Args: { p_session_id: string; p_terms: Json }
        Returns: undefined
      }
      set_challan_template: {
        Args: {
          p_bank_account_no: string
          p_bank_account_title: string
          p_bank_name: string
          p_campus_id: string
          p_footer_note_en?: string
          p_footer_note_ur?: string
          p_logo_path?: string
        }
        Returns: undefined
      }
      set_class_level_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: undefined
      }
      set_concession_scheme_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: undefined
      }
      set_current_session: {
        Args: { p_session_id: string }
        Returns: undefined
      }
      set_fee_head_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: undefined
      }
      set_fee_head_priority: {
        Args: { p_fee_head_id: string; p_priority: number }
        Returns: undefined
      }
      set_fee_policy: {
        Args: {
          p_allow_negative_net?: boolean
          p_max_stacked_concession_pct?: number
        }
        Returns: undefined
      }
      set_gr_sequence: {
        Args: {
          p_campus_id: string
          p_next_value: number
          p_pad_width?: number
          p_prefix: string
        }
        Returns: undefined
      }
      set_leave_approval_chain_step: {
        Args: {
          p_approver_role: Database["public"]["Enums"]["app_role"]
          p_campus_id: string
          p_leave_type_id: string
          p_sla_hours?: number
          p_step_no: number
        }
        Returns: string
      }
      set_room_active: {
        Args: { p_id: string; p_inactive_from?: string; p_is_active: boolean }
        Returns: undefined
      }
      set_section_stream: {
        Args: { p_section_id: string; p_stream_id: string }
        Returns: undefined
      }
      set_sibling_discount_scheme: {
        Args: { p_scheme_id: string; p_sibling_rank: number }
        Returns: undefined
      }
      set_stream_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: undefined
      }
      set_subject_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: undefined
      }
      set_subject_board_code: {
        Args: {
          p_board: Database["public"]["Enums"]["board"]
          p_board_code: string
          p_subject_id: string
        }
        Returns: undefined
      }
      show_limit: { Args: never; Returns: number }
      show_trgm: { Args: { "": string }; Returns: string[] }
      student_balance: { Args: { p_enrolment_id: string }; Returns: number }
      suggest_rooms_for_type: {
        Args: {
          p_campus_id: string
          p_preferred_room_type: Database["public"]["Enums"]["room_type_enum"]
        }
        Returns: {
          block_label: string | null
          campus_id: string
          capacity: number
          code: string
          created_at: string
          id: string
          inactive_from: string | null
          is_active: boolean
          name: string
          room_type: Database["public"]["Enums"]["room_type_enum"]
          tenant_id: string
        }[]
        SetofOptions: {
          from: "*"
          to: "room"
          isOneToOne: false
          isSetofReturn: true
        }
      }
      suggest_substitute_teachers: {
        Args: {
          p_as_of_date?: string
          p_class_level_id: string
          p_subject_id: string
        }
        Returns: {
          full_name: string
          max_class_ordinal: number
          min_class_ordinal: number
          out_of_range: boolean
          source: Database["public"]["Enums"]["competency_source_enum"]
          staff_id: string
        }[]
      }
      swap_class_level_ordinals: {
        Args: { p_id_a: string; p_id_b: string }
        Returns: undefined
      }
      unlink_guardian: {
        Args: { p_guardian_id: string; p_student_id: string }
        Returns: undefined
      }
      update_structure_line_amount: {
        Args: { p_amount_paisa: number; p_line_id: string }
        Returns: undefined
      }
      upsert_class_subject: {
        Args: {
          p_campus_id: string
          p_choose_n?: number
          p_class_level_id: string
          p_elective_bucket?: number
          p_is_compulsory?: boolean
          p_max_marks?: number
          p_session_id: string
          p_stream_id?: string
          p_subject_id: string
          p_weekly_periods: number
        }
        Returns: string
      }
      verify_competency: {
        Args: {
          p_document_path?: string
          p_staff_id: string
          p_subject_id: string
        }
        Returns: string
      }
      working_days_between: {
        Args: { p_campus_id: string; p_from: string; p_to: string }
        Returns: number
      }
    }
    Enums: {
      academic_group:
        | "pre_medical"
        | "pre_engineering"
        | "computer_science"
        | "commerce"
        | "arts"
      allocation_role: "primary" | "assistant"
      app_role:
        | "super_admin"
        | "owner"
        | "principal"
        | "vice_principal"
        | "admissions_officer"
        | "accountant"
        | "exam_controller"
        | "head_of_department"
        | "class_teacher"
        | "subject_teacher"
        | "hr_manager"
        | "librarian"
        | "transport_manager"
        | "receptionist"
        | "parent"
        | "student"
        | "nurse"
      application_status:
        | "submitted"
        | "under_review"
        | "offered"
        | "accepted"
        | "declined"
        | "lapsed"
        | "enrolled"
        | "rejected"
      approval_decision: "pending" | "approved" | "rejected" | "escalated"
      attendance_source: "manual" | "biometric" | "leave"
      attendance_status: "present" | "absent" | "on_leave" | "half_day" | "late"
      audit_action: "insert" | "update" | "delete"
      board:
        | "FBISE"
        | "PUNJAB"
        | "SINDH"
        | "KPK"
        | "BALOCHISTAN"
        | "AKU_EB"
        | "CAMBRIDGE"
      campus_status: "active" | "archived"
      competency_source_enum: "DECLARED" | "INFERRED" | "VERIFIED"
      concession_award_status: "pending" | "approved" | "rejected" | "expired"
      concession_calc_type: "percentage" | "fixed_amount"
      contract_type:
        | "permanent"
        | "contract"
        | "probation"
        | "visiting"
        | "part_time"
      disability_type:
        | "none"
        | "visual_impairment"
        | "hearing_impairment"
        | "physical_disability"
        | "learning_disability"
        | "speech_impairment"
        | "autism_spectrum"
        | "other"
      employment_status: "active" | "on_leave" | "suspended" | "exited"
      enquiry_source: "walk_in" | "phone" | "web" | "referral" | "other"
      enquiry_status: "open" | "converted" | "lost" | "merged"
      enrolment_status: "active" | "transferred" | "left" | "graduated"
      fee_challan_line_type: "charge" | "concession" | "arrears" | "late_fee"
      fee_challan_status: "unpaid" | "part_paid" | "paid" | "cancelled"
      fee_frequency: "monthly" | "quarterly" | "annual" | "one_time"
      fee_ledger_direction: "debit" | "credit"
      fee_ledger_entry_type:
        | "charge"
        | "concession"
        | "late_fee"
        | "payment"
        | "refund"
        | "adjustment"
        | "write_off"
        | "reversal"
      fee_payment_mode:
        | "cash"
        | "bank_challan"
        | "online"
        | "cheque"
        | "adjustment"
      fee_plan_override_status:
        | "none"
        | "pending_approval"
        | "approved"
        | "rejected"
      fee_structure_status: "draft" | "published" | "superseded"
      followup_channel: "call" | "whatsapp" | "sms" | "email" | "in_person"
      followup_outcome:
        | "connected"
        | "no_answer"
        | "wrong_number"
        | "call_later"
        | "visit_scheduled"
        | "not_interested"
      gender: "male" | "female" | "other"
      guardian_relationship:
        | "father"
        | "mother"
        | "grandparent"
        | "uncle"
        | "aunt"
        | "sibling"
        | "legal_guardian"
        | "other"
      id_document_type: "cnic" | "passport"
      late_fee_basis: "flat" | "per_day" | "percentage"
      leave_accrual_method: "annual_grant" | "monthly_accrual" | "none"
      leave_application_status:
        | "pending"
        | "approved"
        | "rejected"
        | "cancelled"
      leave_ledger_entry_type:
        | "grant"
        | "accrual"
        | "hold"
        | "hold_release"
        | "consumption"
        | "encashment"
        | "carry_forward"
      offer_decline_reason:
        | "fee_too_high"
        | "chose_other_school"
        | "relocation"
        | "distance"
        | "other"
      offer_status: "issued" | "accepted" | "declined" | "lapsed"
      room_type_enum:
        | "CLASSROOM"
        | "SCIENCE_LAB"
        | "COMPUTER_LAB"
        | "HALL"
        | "LIBRARY"
        | "PRAYER_AREA"
      section_medium: "ENGLISH" | "URDU"
      section_shift: "MORNING" | "AFTERNOON"
      session_status: "planned" | "active" | "closed" | "archived"
      status_reason_code:
        | "admission"
        | "promotion"
        | "transfer_out"
        | "transfer_in"
        | "graduation"
        | "long_absence"
        | "disciplinary"
        | "fee_default"
        | "readmission"
        | "medical"
        | "relocation"
        | "other"
      student_status:
        | "active"
        | "inactive"
        | "left"
        | "graduated"
        | "expelled"
        | "transferred"
        | "struck_off"
        | "on_leave"
      subject_type: "CORE" | "ELECTIVE" | "ADDITIONAL" | "NON_EXAMINABLE"
      tenant_status: "provisioning" | "active" | "suspended" | "closed"
      transport_direction: "pickup" | "drop" | "both"
      user_status: "active" | "suspended" | "terminated"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      academic_group: [
        "pre_medical",
        "pre_engineering",
        "computer_science",
        "commerce",
        "arts",
      ],
      allocation_role: ["primary", "assistant"],
      app_role: [
        "super_admin",
        "owner",
        "principal",
        "vice_principal",
        "admissions_officer",
        "accountant",
        "exam_controller",
        "head_of_department",
        "class_teacher",
        "subject_teacher",
        "hr_manager",
        "librarian",
        "transport_manager",
        "receptionist",
        "parent",
        "student",
        "nurse",
      ],
      application_status: [
        "submitted",
        "under_review",
        "offered",
        "accepted",
        "declined",
        "lapsed",
        "enrolled",
        "rejected",
      ],
      approval_decision: ["pending", "approved", "rejected", "escalated"],
      attendance_source: ["manual", "biometric", "leave"],
      attendance_status: ["present", "absent", "on_leave", "half_day", "late"],
      audit_action: ["insert", "update", "delete"],
      board: [
        "FBISE",
        "PUNJAB",
        "SINDH",
        "KPK",
        "BALOCHISTAN",
        "AKU_EB",
        "CAMBRIDGE",
      ],
      campus_status: ["active", "archived"],
      competency_source_enum: ["DECLARED", "INFERRED", "VERIFIED"],
      concession_award_status: ["pending", "approved", "rejected", "expired"],
      concession_calc_type: ["percentage", "fixed_amount"],
      contract_type: [
        "permanent",
        "contract",
        "probation",
        "visiting",
        "part_time",
      ],
      disability_type: [
        "none",
        "visual_impairment",
        "hearing_impairment",
        "physical_disability",
        "learning_disability",
        "speech_impairment",
        "autism_spectrum",
        "other",
      ],
      employment_status: ["active", "on_leave", "suspended", "exited"],
      enquiry_source: ["walk_in", "phone", "web", "referral", "other"],
      enquiry_status: ["open", "converted", "lost", "merged"],
      enrolment_status: ["active", "transferred", "left", "graduated"],
      fee_challan_line_type: ["charge", "concession", "arrears", "late_fee"],
      fee_challan_status: ["unpaid", "part_paid", "paid", "cancelled"],
      fee_frequency: ["monthly", "quarterly", "annual", "one_time"],
      fee_ledger_direction: ["debit", "credit"],
      fee_ledger_entry_type: [
        "charge",
        "concession",
        "late_fee",
        "payment",
        "refund",
        "adjustment",
        "write_off",
        "reversal",
      ],
      fee_payment_mode: [
        "cash",
        "bank_challan",
        "online",
        "cheque",
        "adjustment",
      ],
      fee_plan_override_status: [
        "none",
        "pending_approval",
        "approved",
        "rejected",
      ],
      fee_structure_status: ["draft", "published", "superseded"],
      followup_channel: ["call", "whatsapp", "sms", "email", "in_person"],
      followup_outcome: [
        "connected",
        "no_answer",
        "wrong_number",
        "call_later",
        "visit_scheduled",
        "not_interested",
      ],
      gender: ["male", "female", "other"],
      guardian_relationship: [
        "father",
        "mother",
        "grandparent",
        "uncle",
        "aunt",
        "sibling",
        "legal_guardian",
        "other",
      ],
      id_document_type: ["cnic", "passport"],
      late_fee_basis: ["flat", "per_day", "percentage"],
      leave_accrual_method: ["annual_grant", "monthly_accrual", "none"],
      leave_application_status: [
        "pending",
        "approved",
        "rejected",
        "cancelled",
      ],
      leave_ledger_entry_type: [
        "grant",
        "accrual",
        "hold",
        "hold_release",
        "consumption",
        "encashment",
        "carry_forward",
      ],
      offer_decline_reason: [
        "fee_too_high",
        "chose_other_school",
        "relocation",
        "distance",
        "other",
      ],
      offer_status: ["issued", "accepted", "declined", "lapsed"],
      room_type_enum: [
        "CLASSROOM",
        "SCIENCE_LAB",
        "COMPUTER_LAB",
        "HALL",
        "LIBRARY",
        "PRAYER_AREA",
      ],
      section_medium: ["ENGLISH", "URDU"],
      section_shift: ["MORNING", "AFTERNOON"],
      session_status: ["planned", "active", "closed", "archived"],
      status_reason_code: [
        "admission",
        "promotion",
        "transfer_out",
        "transfer_in",
        "graduation",
        "long_absence",
        "disciplinary",
        "fee_default",
        "readmission",
        "medical",
        "relocation",
        "other",
      ],
      student_status: [
        "active",
        "inactive",
        "left",
        "graduated",
        "expelled",
        "transferred",
        "struck_off",
        "on_leave",
      ],
      subject_type: ["CORE", "ELECTIVE", "ADDITIONAL", "NON_EXAMINABLE"],
      tenant_status: ["provisioning", "active", "suspended", "closed"],
      transport_direction: ["pickup", "drop", "both"],
      user_status: ["active", "suspended", "terminated"],
    },
  },
} as const

