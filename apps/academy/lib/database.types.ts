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
          staff_id: string
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
          staff_id: string
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
          staff_id?: string
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
          staff_id: string
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
          staff_id: string
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
          staff_id?: string
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
    }
    Functions: {
      accept_invitation: { Args: { p_token: string }; Returns: string }
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
        Returns: string
      }
      confirm_family_group: { Args: { p_group_id: string }; Returns: undefined }
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
      custom_access_token_hook: { Args: { event: Json }; Returns: Json }
      delete_class_level: { Args: { p_id: string }; Returns: undefined }
      delete_stream: { Args: { p_id: string }; Returns: undefined }
      enrol_student: {
        Args: {
          p_override_reason?: string
          p_section_id: string
          p_student_id: string
        }
        Returns: string
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
      fn_expire_offers: { Args: never; Returns: number }
      fn_extend_offer: {
        Args: { p_new_expires_at: string; p_offer_id: string; p_reason: string }
        Returns: undefined
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
      fn_issue_offer: {
        Args: {
          p_admission_fee_amount: number
          p_application_id: string
          p_valid_days?: number
        }
        Returns: string
      }
      fn_merge_family_groups: {
        Args: { p_keep_id: string; p_merge_id: string }
        Returns: undefined
      }
      fn_next_enquiry_no: {
        Args: { p_campus_id: string; p_session_id: string }
        Returns: string
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
      normalize_pk_phone: { Args: { p_phone: string }; Returns: string }
      provision_tenant: {
        Args: { p_legal_name: string; p_owner_email: string; p_slug: string }
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
      seed_default_class_levels: {
        Args: { p_tenant_id: string }
        Returns: undefined
      }
      seed_tenant_roles: { Args: { p_tenant_id: string }; Returns: undefined }
      set_academic_terms: {
        Args: { p_session_id: string; p_terms: Json }
        Returns: undefined
      }
      set_class_level_active: {
        Args: { p_id: string; p_is_active: boolean }
        Returns: undefined
      }
      set_current_session: {
        Args: { p_session_id: string }
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
      set_section_stream: {
        Args: { p_section_id: string; p_stream_id: string }
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
      swap_class_level_ordinals: {
        Args: { p_id_a: string; p_id_b: string }
        Returns: undefined
      }
      unlink_guardian: {
        Args: { p_guardian_id: string; p_student_id: string }
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
      application_status:
        | "submitted"
        | "under_review"
        | "offered"
        | "accepted"
        | "declined"
        | "lapsed"
        | "enrolled"
        | "rejected"
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
      enquiry_source: "walk_in" | "phone" | "web" | "referral" | "other"
      enquiry_status: "open" | "converted" | "lost"
      enrolment_status: "active" | "transferred" | "left" | "graduated"
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
      offer_decline_reason:
        | "fee_too_high"
        | "chose_other_school"
        | "relocation"
        | "distance"
        | "other"
      offer_status: "issued" | "accepted" | "declined" | "lapsed"
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
      enquiry_source: ["walk_in", "phone", "web", "referral", "other"],
      enquiry_status: ["open", "converted", "lost"],
      enrolment_status: ["active", "transferred", "left", "graduated"],
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
      offer_decline_reason: [
        "fee_too_high",
        "chose_other_school",
        "relocation",
        "distance",
        "other",
      ],
      offer_status: ["issued", "accepted", "declined", "lapsed"],
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
      user_status: ["active", "suspended", "terminated"],
    },
  },
} as const

