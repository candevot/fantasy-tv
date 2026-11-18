package android.content;
public interface DialogInterface {
    void cancel();
    void dismiss();
    interface OnCancelListener { void onCancel(DialogInterface d); }
    interface OnClickListener { void onClick(DialogInterface d, int w); }
    interface OnDismissListener { void onDismiss(DialogInterface d); }
    interface OnMultiChoiceClickListener { void onClick(DialogInterface d, int w, boolean b); }
}
