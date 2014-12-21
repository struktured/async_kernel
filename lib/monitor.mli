(** The part of the {!Execution_context} that determines what to do when there is an
    unhandled exception.

    Every Async computation runs within the context of some monitor, which, when the
    computation is running, is referred to as the "current" monitor.  Monitors are
    arranged in a tree -- when a new monitor is created, it is a child of the current
    monitor.

    If a computation raises an unhandled exception, the behavior depends on whether the
    current monitor is "detached" or "attached".  If the monitor has been "detached", via
    one of the [detach*] functions, then whomever detached it is responsible for dealing
    with the exception.  If the monitor is still attached, then the exception bubbles to
    monitor's parent.  If an exception bubbles to the initial monitor, i.e. the root of
    the monitor tree, that prints an unhandled-exception message and calls exit 1.

    {1 NOTE ABOUT THE TOPLEVEL MONITOR }

    It is important to note that in the toplevel monitor, exceptions will only be caught
    in the Async part of a computation.  For example, in:

    {[
      upon (f ()) g
    ]}

    if [f] raises, the exception will not go to a monitor; it will go to the next caml
    exception handler on the stack.  Any exceptions raised by [g] will be caught by the
    scheduler and propagated to the toplevel monitor.  Because of this it is advised to
    always use [Scheduler.schedule] or [Scheduler.within].  For example:

    {[
      Scheduler.within (fun () -> upon (f ()) g)
    ]}

    This code will catch an exception in either [f] or [g], and propagate it to the
    monitor.

    This is only relevant to the toplevel monitor because if you create another monitor
    and you wish to run code within it you have no choice but to use [Scheduler.within].
    [try_with] creates its own monitor and uses [Scheduler.within], so it does not have
    this problem. *)
open Core.Std

type t = Raw_monitor.t with sexp_of

type 'a with_optional_monitor_name =
  ?here : Source_code_position.t
  -> ?info : Info.t
  -> ?name : string
  -> 'a

(** [create ()] returns a new monitor whose parent is the current monitor. *)
val create : (unit -> t) with_optional_monitor_name

(** [name t] returns the name of the monitor, or a unique id if no name was supplied to
    [create]. *)
val name : t -> Info.t

val parent : t -> t option

val depth : t -> int

(** [current ()] returns the current monitor *)
val current : unit -> t


(** [detach t] detaches [t] so that errors raised to [t] are not passed to [t]'s parent
    monitor.  If those errors aren't handled in some other way, then they will effectively
    be ignored.  One should usually use [detach_and_iter_errors] so that errors are not
    ignored. *)
val detach : t -> unit


(** [detach_and_iter_errors t ~f] detaches [t] and passes to [f] all subsequent errors
    that reach [t], stopping iteration if [f] raises an exception.  An exception raised by
    [f] is sent to the monitor in effect when [detach_and_iter_errors] was called. *)
val detach_and_iter_errors : t -> f:(exn -> unit) -> unit

(** [detach_and_get_next_error t] detaches [t] and returns a deferred that becomes
    determined with the next error that reaches [t] (possibly never). *)
val detach_and_get_next_error : t -> exn Deferred.t

(** [detach_and_get_error_stream t] detaches [t] and returns a stream of all subsequent
    errors that reach [t].

    [Stream.iter (detach_and_get_error_stream t) ~f] is equivalent to
    [detach_and_iter_errors t ~f]. *)
val detach_and_get_error_stream : t -> exn Tail.Stream.t

(** [get_next_error t] returns a deferred that becomes determined the next time [t] gets
    an error, if ever.  Calling [get_next_error t] does not detach [t], and if no other
    call has detached [t], then errors will still bubble up the monitor tree. *)
val get_next_error : t -> exn Deferred.t

(** [extract_exn exn] extracts the exn from an error exn that comes from a monitor.  If it
    is not supplied such an error exn, it returns the exn itself. *)
val extract_exn : exn -> exn

(** [has_seen_error t] returns true iff the monitor has ever seen an error. *)
val has_seen_error : t -> bool

(** [send_exn t exn ?backtrace] sends the exception [exn] as an error to be handled by
    monitor [t].  By default, the error will not contain a backtrace.  However, the caller
    can supply one using [`This], or use [`Get] to request that [send_exn] obtain one
    using [Exn.backtrace ()]. *)
val send_exn : t -> ?backtrace:[ `Get | `This of string ] -> exn -> unit


(** [try_with f] runs [f ()] in a monitor and returns the result as [Ok x] if [f] finishes
    normally, or returns [Error e] if there is some error.  It either runs [f] now, if
    [run = `Now], or schedules a job to run [f], if [run = `Schedule].  Once a result is
    returned, the rest of the errors raised by [f] are ignored or re-raised, as per
    [rest].  [try_with] never raises synchronously, and may only raise asynchronously with
    [rest = `Raise].

    The [name] argument is used to give a name to the monitor the computation will be
    running in.  This name will appear when printing errors.

    [try_with] runs [f ()] in a new monitor [t] that has no parent.  This works because
    [try_with] calls [detach_and_get_error_stream t] and explicitly handles all errors
    sent to [t].  No errors would ever implicitly propagate to [t]'s parent, although
    [try_with] will explicitly send them to [t]'s parent with [rest = `Raise].

    If [extract_exn = true], then in an [Error exn] result, the [exn] will be the actual
    exception raised by the computation.  If [extract_exn = false], then the [exn] will
    include additional information, like the monitor and backtrace.  One typically wants
    [extract_exn = false] due to the additional information.  However, sometimes one wants
    the concision of [extract_exn = true]. *)
val try_with
  : (?extract_exn : bool (** default is [false] *)
     -> ?run : [ `Now | `Schedule ]  (** default is [`Schedule] *)
     -> ?rest : [ `Ignore | `Raise ] (** default is [`Ignore] *)
     -> (unit -> 'a Deferred.t)
     -> ('a, exn) Result.t Deferred.t
    ) with_optional_monitor_name

(** [try_with_rest_handling] determines how [try_with f ~rest] determines the [rest] value
    it actually uses.  If [!try_with_rest_handling = `Default d], then [d] is the default
    value for [rest], but can be overriden by supplying [rest] to [try_with].  If
    [!try_with_rest_handling = Force f], then the [rest] supplied to [try_with] is not
    used, and [f] is.

    Initially, [!try_with_rest_handling = `Default `Ignore]. *)
val try_with_rest_handling
  : [ `Default of [ `Ignore | `Raise ]
    | `Force of   [ `Ignore | `Raise ]
    ] ref

(** [try_with_ignored_exn_handling] describes what should happen when [try_with]'s [rest]
    value is [`Ignore], as determined by [!try_with_rest_handling] and the [~rest]
    supplied to [try_with].

    Initially, [!try_with_ignored_exn_handling = `Ignore]. *)
val try_with_ignored_exn_handling
  : [ `Ignore              (* really ignore the exception *)
    | `Eprintf             (* eprintf the exception *)
    | `Run of exn -> unit  (* apply the function to the exception *)
    ] ref

(** [handle_errors ?name f handler] runs [f ()] inside a new monitor with the optionally
    supplied name, and calls [handler error] on every error raised to that monitor.  Any
    error raised by [handler] goes to the monitor in effect when [handle_errors] was
    called.

    Errors that are raised after [f ()] becomes determined will still be sent to
    [handler]; i.e. the new monitor lives as long as jobs created by [f] live. *)
val handle_errors
  : ((unit -> 'a Deferred.t)
     -> (exn -> unit)
     -> 'a Deferred.t
    ) with_optional_monitor_name

(** [catch_stream ?name f] runs [f ()] inside a new monitor [m] and returns the stream of
    errors raised to [m]. *)
val catch_stream : ((unit -> unit) -> exn Tail.Stream.t) with_optional_monitor_name

(** [catch ?name f] runs [f ()] inside a new monitor [m] and returns the first error
    raised to [m]. *)
val catch : ((unit -> unit) -> exn Deferred.t) with_optional_monitor_name

(** [protect f ~finally] runs [f ()] and then [finally] regardless of the success or
    failure of [f].  It re-raises any exception thrown by [f] or returns whatever [f]
    returned.

    The [name] argument is used to give a name to the monitor the computation will be
    running in.  This name will appear when printing the errors. *)
val protect
  : ((unit -> 'a Deferred.t)
     -> finally:(unit -> unit Deferred.t)
     -> 'a Deferred.t
    ) with_optional_monitor_name

val main : t

(** [kill t] causes [t] and all of [t]'s descendants to never start another job.  The job
    that calls [kill] will complete, even if it is a descendant of [t].

    [kill] can break user expectations.  For example, users expect in [protect f ~finally]
    that [finally] will eventually run.  However, if the monitor in which [finally] would
    run is killed, then [finally] will never run. *)
val kill : t -> unit

(** [is_alive t] returns [true] iff none of [t] or its ancestors have been killed. *)
val is_alive : t -> bool

module Exported_for_scheduler : sig
  type 'a with_options =
    ?monitor:t
    -> ?priority:Priority.t
    -> 'a
  val within'   : ((unit -> 'a Deferred.t) -> 'a Deferred.t) with_options
  val within    : ((unit -> unit         ) -> unit         ) with_options
  val within_v  : ((unit -> 'a           ) -> 'a option    ) with_options
  val schedule' : ((unit -> 'a Deferred.t) -> 'a Deferred.t) with_options
  val schedule  : ((unit -> unit         ) -> unit         ) with_options

  val within_context : Execution_context.t -> (unit -> 'a) -> ('a, unit) Result.t

  val preserve_execution_context  : ('a -> unit)          -> ('a -> unit)          Staged.t
  val preserve_execution_context' : ('a -> 'b Deferred.t) -> ('a -> 'b Deferred.t) Staged.t

end
